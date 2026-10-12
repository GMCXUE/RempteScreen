//! ScreenCaptureKit provides NV12; Windows Graphics Capture provides BGRA.
use livekit::webrtc::prelude::I420Buffer;
use scap::frame::Frame;

pub fn scale_to_tier(mut buffer: I420Buffer, height_tier: u32) -> I420Buffer {
    use livekit::webrtc::prelude::VideoBuffer;
    if height_tier > 0 && buffer.height() > height_tier {
        let width =
            ((buffer.width() as u64 * height_tier as u64 / buffer.height() as u64) as i32 / 2) * 2;
        buffer.scale(width.max(2), height_tier as i32)
    } else {
        buffer
    }
}

pub fn convert(frame: &Frame) -> Result<I420Buffer, String> {
    let (width, height) = match frame {
        Frame::YUVFrame(f) => (f.width, f.height),
        Frame::BGRA(f) => (f.width, f.height),
        _ => return Err("屏幕采集返回了不支持的图像格式".into()),
    };
    if width <= 0 || height <= 0 || width > 16384 || height > 16384 {
        return Err("屏幕采集返回了无效的图像尺寸".into());
    }
    let mut buffer = I420Buffer::new(width as u32, height as u32);
    let (sy, su, sv) = buffer.strides();
    let cw = buffer.chroma_width() as usize;
    let ch = buffer.chroma_height() as usize;
    let (y, u, v) = buffer.data_mut();
    match frame {
        Frame::YUVFrame(f) => {
            let ys = usize::try_from(f.luminance_stride).unwrap_or(0);
            let cs = usize::try_from(f.chrominance_stride).unwrap_or(0);
            if ys < width as usize
                || cs < cw * 2
                || f.luminance_bytes.len() < ys * height as usize
                || f.chrominance_bytes.len() < cs * ch
            {
                return Err("屏幕采集返回了不完整的 NV12 图像".into());
            }
            for row in 0..height as usize {
                y[row * sy as usize..row * sy as usize + width as usize]
                    .copy_from_slice(&f.luminance_bytes[row * ys..row * ys + width as usize]);
            }
            for row in 0..ch {
                for col in 0..cw {
                    u[row * su as usize + col] = f.chrominance_bytes[row * cs + col * 2];
                    v[row * sv as usize + col] = f.chrominance_bytes[row * cs + col * 2 + 1];
                }
            }
        }
        Frame::BGRA(f) => {
            let stride = f.data.len() / height as usize;
            if f.data.len() % height as usize != 0
                || stride < width as usize * 4
                || stride > u32::MAX as usize
            {
                return Err("屏幕采集返回了不完整的 BGRA 图像".into());
            }
            // libyuv ARGB is BGRA in memory on little-endian desktop CPUs.
            livekit::webrtc::native::yuv_helper::argb_to_i420(
                &f.data,
                stride as u32,
                y,
                sy,
                u,
                su,
                v,
                sv,
                width,
                height,
            );
        }
        _ => unreachable!(),
    }
    Ok(buffer)
}

#[cfg(test)]
mod tests {
    use super::*;
    use scap::frame::{BGRAFrame, YUVFrame};

    #[test]
    fn windows_bgra_preserves_red_and_odd_dimensions_with_padding() {
        let mut data = vec![0; 16 * 3];
        for row in data.chunks_mut(16) {
            for pixel in row[..12].chunks_mut(4) {
                pixel.copy_from_slice(&[0, 0, 255, 255]);
            }
        }
        let f = Frame::BGRA(BGRAFrame {
            display_time: 0,
            width: 3,
            height: 3,
            data,
        });
        let b = convert(&f).unwrap();
        assert_eq!((b.chroma_width(), b.chroma_height()), (2, 2));
        let (y, u, v) = b.data();
        assert!(y.iter().all(|x| (80..=83).contains(x)));
        assert!(u.iter().all(|x| (89..=92).contains(x)));
        assert!(v.iter().all(|x| (238..=241).contains(x)));
    }

    #[test]
    fn mac_nv12_preserves_planes_with_padding() {
        let f = Frame::YUVFrame(YUVFrame {
            display_time: 0,
            width: 2,
            height: 2,
            luminance_stride: 4,
            chrominance_stride: 4,
            luminance_bytes: vec![1, 2, 0, 0, 3, 4, 0, 0],
            chrominance_bytes: vec![5, 6, 0, 0],
        });
        let b = convert(&f).unwrap();
        assert_eq!(b.data(), (&[1, 2, 3, 4][..], &[5][..], &[6][..]));
    }

    #[test]
    fn rejects_truncated_or_invalid_frames() {
        for (width, height, data) in [(2, 2, vec![0; 12]), (-1, 2, vec![]), (2, 0, vec![])] {
            assert!(convert(&Frame::BGRA(BGRAFrame {
                display_time: 0,
                width,
                height,
                data
            }))
            .is_err());
        }
    }
}
