package com.cloudwebrtc.webrtc.audio;

import static org.junit.Assert.*;
import java.nio.ByteBuffer;
import org.junit.Test;

public class PlaybackAudioCaptureTest {
    @Test
    public void revokedProjectionSendsSilenceAndKeepsRealtimePacing() {
        PlaybackAudioCapture capture = new PlaybackAudioCapture();
        capture.stop(); // No recorder remains after the user revokes projection.
        ByteBuffer buffer = ByteBuffer.allocateDirect(480 * 2);
        long started = System.nanoTime();
        for (int frame = 0; frame < 5; frame++) {
            // Simulate a reused WebRTC buffer containing old/microphone samples.
            for (int i = 0; i < buffer.capacity(); i++) buffer.put(i, (byte) 127);
            capture.onBuffer(buffer, 2 /* PCM_16BIT */, 1, 48000, 0, 0);
            for (int i = 0; i < buffer.capacity(); i++) assertEquals(0, buffer.get(i));
        }
        // Without pacing, WebRTC's disabled microphone loop would spin at full CPU
        // and submit thousands of silent frames per second.
        assertTrue("five 10 ms buffers must be paced", System.nanoTime() - started >= 35_000_000L);
    }
}
