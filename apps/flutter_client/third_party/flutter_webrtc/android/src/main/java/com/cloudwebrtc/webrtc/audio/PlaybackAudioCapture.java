package com.cloudwebrtc.webrtc.audio;

import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioPlaybackCaptureConfiguration;
import android.media.AudioRecord;
import android.media.MediaRecorder;
import android.media.projection.MediaProjection;
import android.os.Build;
import android.os.Process;
import android.util.Log;
import androidx.annotation.RequiresApi;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.concurrent.locks.LockSupport;
import org.webrtc.audio.JavaAudioDeviceModule;

/** Supplies internal playback PCM to WebRTC without opening its microphone recorder. */
public final class PlaybackAudioCapture implements JavaAudioDeviceModule.AudioBufferCallback {
    public static final int SAMPLE_RATE = 48000;
    private static final String TAG = "PlaybackAudioCapture";
    private AudioRecord recorder;
    private AudioRecord microphone;
    private volatile boolean screenAudio;
    private long nextFrameNs;
    private boolean readErrorReported;
    private int frames;
    private int peak;

    public synchronized void setMicrophoneEnabled(boolean enabled) {
        if (microphone != null) {
            try { microphone.stop(); } catch (IllegalStateException ignored) { }
            microphone.release();
            microphone = null;
        }
        if (!enabled) return;
        if (recorder == null) throw new IllegalStateException("投屏声音尚未连接");
        int minimum = AudioRecord.getMinBufferSize(SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT);
        AudioRecord input = new AudioRecord(MediaRecorder.AudioSource.MIC, SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
                Math.max(minimum * 2, SAMPLE_RATE / 10 * 2));
        try {
            if (input.getState() != AudioRecord.STATE_INITIALIZED) throw new IllegalStateException("麦克风初始化失败");
            input.startRecording();
            if (input.getRecordingState() != AudioRecord.RECORDSTATE_RECORDING) throw new IllegalStateException("麦克风启动失败");
            microphone = input;
        } catch (RuntimeException error) {
            input.release();
            throw error;
        }
    }

    public synchronized boolean useMicrophoneInput() {
        if (recorder != null) return false;
        screenAudio = false;
        return true;
    }

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
        setMicrophoneEnabled(false);
        screenAudio = true;
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
    public long onBuffer(ByteBuffer buffer, int format, int channels,
                                      int sampleRate, int bytesRead, long timestampNs) {
        if (!screenAudio) return timestampNs;
        // With setAudioRecordEnabled(false), WebRTC no longer has a blocking mic
        // read to pace its loop. Supply exactly one buffer per audio frame interval.
        long now = System.nanoTime();
        long frameNs = buffer.capacity() * 1_000_000_000L / (2L * channels * sampleRate);
        if (nextFrameNs < now - frameNs) nextFrameNs = now;
        while ((now = System.nanoTime()) < nextFrameNs) LockSupport.parkNanos(nextFrameNs - now);
        nextFrameNs += frameNs;
        synchronized (this) {
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
            // Android WebRTC exposes one PCM input for all audio sources. Keep
            // playback intact and mix voice only after an explicit user toggle.
            if (microphone != null) {
                byte[] voice = new byte[buffer.capacity()];
                int voiceCount = microphone.read(voice, 0, voice.length, AudioRecord.READ_NON_BLOCKING);
                for (int i = 0; i + 1 < voiceCount; i += 2) {
                    int sample = (short) ((voice[i] & 255) | (voice[i + 1] << 8));
                    int mixed = buffer.getShort(i) + sample;
                    buffer.putShort(i, (short) Math.max(-32768, Math.min(32767, mixed)));
                }
            }
            for (int i = 0; i + 1 < count; i += 2) peak = Math.max(peak, Math.abs((int) buffer.getShort(i)));
            if (++frames % 500 == 0) {
                Log.i(TAG, "Internal audio: " + frames + " frames, peak=" + peak);
                peak = 0;
            }
            buffer.rewind();
            return System.nanoTime();
        }
    }
}
