// 尖刺 1：验证 macOS 原生采集（ScreenCaptureKit）能否跑满 60fps。
// 连续采集 10 秒，按秒统计帧数。目标：每秒 ≥60。
use std::time::{Duration, Instant};

fn main() {
    if !scap::has_permission() {
        println!("没有屏幕录制权限，正在请求……请在系统弹窗中允许后重跑本程序");
        scap::request_permission();
        return;
    }

    let options = scap::capturer::Options {
        fps: 60,
        output_type: scap::frame::FrameType::BGR0,
        show_cursor: true,
        ..Default::default()
    };
    let mut capturer = scap::capturer::Capturer::build(options).expect("创建采集器失败");
    capturer.start_capture();
    println!("采集已启动，统计 10 秒……");

    let mut second_start = Instant::now();
    let mut frames_this_second = 0u32;
    let mut total = 0u32;
    let mut seconds_done = 0u32;

    while seconds_done < 10 {
        if let Ok(frame) = capturer.get_next_frame() {
            let _size = match frame {
                scap::frame::Frame::BGR0(ref f) => (f.width, f.height),
                _ => (0, 0),
            };
            frames_this_second += 1;
            total += 1;
        }

        if second_start.elapsed() >= Duration::from_secs(1) {
            seconds_done += 1;
            println!("第 {:2} 秒：{:3} fps（累计 {} 帧）", seconds_done, frames_this_second, total);
            frames_this_second = 0;
            second_start = Instant::now();
        }
    }

    capturer.stop_capture();
    println!("平均帧率：{:.1} fps", total as f64 / 10.0);
}
