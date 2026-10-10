package com.cloudwebrtc.webrtc.audio;

import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioPlaybackCaptureConfiguration;
import android.media.AudioRecord;
import android.media.projection.MediaProjection;
import android.os.Build;
import android.os.Process;
import android.util.Log;
import androidx.annotation.RequiresApi;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import org.webrtc.audio.JavaAudioDeviceModule;

/** Supplies internal playback PCM to WebRTC without opening its microphone recorder. */
public final class PlaybackAudioCapture implements JavaAudioDeviceModule.AudioBufferCallback {
    public static final int SAMPLE_RATE = 48000;
    private static final String TAG = "PlaybackAudioCapture";
    private AudioRecord recorder;
    private boolean screenAudio;
    private boolean readErrorReported;
    private int frames;
    private int peak;

    @RequiresApi(Build.VERSION_CODES.Q)
    public synchronized void start(MediaProjection projection) {
        stop();
        screenAudio = true;
        readErrorReported = false;
        frames = peak = 0;
        AudioPlaybackCaptureConfiguration config = new AudioPlaybackCaptureConfiguration.Builder(projection)
                .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                .addMatchingUsage(AudioAttributes.USAGE_GAME)
                .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                .excludeUid(Process.myUid()) // Do not send remote viewers' audio back to them.
                .build();
        int minBuffer = AudioRecord.getMinBufferSize(SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT);
        if (minBuffer <= 0) throw new IllegalStateException("不支持系统音频采集格式");
        AudioRecord next = new AudioRecord.Builder()
                .setAudioFormat(new AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(SAMPLE_RATE).setChannelMask(AudioFormat.CHANNEL_IN_MONO).build())
                .setBufferSizeInBytes(Math.max(minBuffer * 2, SAMPLE_RATE / 10 * 2))
                .setAudioPlaybackCaptureConfig(config).build();
        try {
            if (next.getState() != AudioRecord.STATE_INITIALIZED) {
                throw new IllegalStateException("系统音频采集器初始化失败");
            }
            next.startRecording();
            if (next.getRecordingState() != AudioRecord.RECORDSTATE_RECORDING) {
                throw new IllegalStateException("系统音频采集未启动");
            }
            recorder = next;
            Log.i(TAG, "Internal audio capture started (48000 Hz, mono)");
        } catch (RuntimeException error) {
            next.release();
            throw error;
        }
    }

    public synchronized void stop() {
        if (recorder != null) {
            try { recorder.stop(); } catch (IllegalStateException ignored) { }
            recorder.release();
            recorder = null;
            Log.i(TAG, "Internal audio capture stopped");
        }
        // Keep replacing buffers with silence until the screen audio track is disposed.
        // Never fall back to transmitting the microphone after projection is revoked.
    }

    @Override
    public synchronized long onBuffer(ByteBuffer buffer, int format, int channels,
                                      int sampleRate, int bytesRead, long timestampNs) {
        if (!screenAudio) return timestampNs;
        for (int i = 0; i < buffer.capacity(); i++) buffer.put(i, (byte) 0);
        if (recorder == null || format != AudioFormat.ENCODING_PCM_16BIT
                || channels != 1 || sampleRate != SAMPLE_RATE) return timestampNs;
        buffer.clear();
        int count = recorder.read(buffer, buffer.capacity(), AudioRecord.READ_NON_BLOCKING);
        if (count < 0 && !readErrorReported) {
            Log.e(TAG, "Internal audio read failed: " + count);
            readErrorReported = true;
        }
        buffer.order(ByteOrder.LITTLE_ENDIAN);
        for (int i = 0; i + 1 < count; i += 2) peak = Math.max(peak, Math.abs((int) buffer.getShort(i)));
        if (++frames % 500 == 0) {
            Log.i(TAG, "Internal audio: " + frames + " frames, peak=" + peak);
            peak = 0;
        }
        buffer.rewind();
        return System.nanoTime();
    }
}
