package com.cloudwebrtc.webrtc;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class RemoteTrackRegistryTest {
  @Test
  public void removeCallbackCanUseANewJavaWrapperForTheSameReceiver() {
    RemoteTrackRegistry<Object> registry = new RemoteTrackRegistry<>();
    registry.put("video", new Object(), "receiver-1");
    assertTrue(registry.removeOwned("video", "receiver-1"));
    assertSame(null, registry.get("video"));
  }

  @Test
  public void lateReceiverRemovalCannotDeleteReplacementTrack() {
    RemoteTrackRegistry<Object> registry = new RemoteTrackRegistry<>();
    Object replacement = new Object();
    registry.put("video", new Object(), "receiver-1");
    registry.put("video", replacement, "receiver-2");
    assertFalse(registry.removeOwned("video", "receiver-1"));
    assertSame(replacement, registry.get("video"));
  }

  @Test
  public void keepsReplacementWhenPreviousTrackIsRemovedLate() {
    RemoteTrackRegistry<Object> registry = new RemoteTrackRegistry<>();
    Object previousTrack = new Object();
    Object replacementTrack = new Object();

    registry.put("video", previousTrack);
    registry.put("video", replacementTrack);

    assertFalse(registry.remove("video", previousTrack));
    assertSame(replacementTrack, registry.get("video"));
    assertTrue(registry.remove("video", replacementTrack));
  }
}
