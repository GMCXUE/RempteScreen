package com.cloudwebrtc.webrtc;

import static org.junit.Assert.*;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.List;
import org.junit.Test;

public class PeerConnectionEventDispatcherTest {
  @Test
  public void snapshotsCallbackOwnedDataBeforeItExpires() {
    ArrayDeque<Runnable> platform = new ArrayDeque<>();
    List<String> events = new ArrayList<>();
    PeerConnectionEventDispatcher dispatcher = new PeerConnectionEventDispatcher(
        platform::add, error -> fail(error.toString()));
    String[] nativeData = {"stream-id"};
    dispatcher.snapshot(() -> {
      String capturedId = nativeData[0];
      return () -> events.add(capturedId);
    });
    nativeData[0] = null;
    platform.remove().run();
    assertEquals(java.util.Arrays.asList("stream-id"), events);
  }

  @Test
  public void snapshotExceptionCannotEscapeTheNativeCallback() {
    List<RuntimeException> errors = new ArrayList<>();
    PeerConnectionEventDispatcher dispatcher = new PeerConnectionEventDispatcher(
        Runnable::run, errors::add);
    dispatcher.snapshot(() -> { throw new IllegalStateException("Stream disposed"); });
    assertEquals(1, errors.size());
  }

  @Test
  public void snapshotsRunAfterNativeCallbackAndInPlatformOrder() {
    ArrayDeque<Runnable> platform = new ArrayDeque<>();
    List<String> events = new ArrayList<>();
    PeerConnectionEventDispatcher dispatcher = new PeerConnectionEventDispatcher(
        platform::add, error -> fail(error.toString()));
    dispatcher.dispatch(() -> events.add("added"));
    dispatcher.dispatch(() -> events.add("removed"));
    assertTrue("Native callback must return without refreshing wrappers", events.isEmpty());
    while (!platform.isEmpty()) platform.remove().run();
    assertEquals(java.util.Arrays.asList("added", "removed"), events);
  }

  @Test
  public void closingPeerDiscardsLateTrackCallbacks() {
    ArrayDeque<Runnable> platform = new ArrayDeque<>();
    PeerConnectionEventDispatcher dispatcher = new PeerConnectionEventDispatcher(
        platform::add, error -> fail(error.toString()));
    dispatcher.dispatch(() -> fail("Callback must not access a disposed peer"));
    dispatcher.close();
    dispatcher.dispatch(() -> fail("Closed peer cannot register another track"));
    while (!platform.isEmpty()) platform.remove().run();
  }

  @Test
  public void disposedWrapperExceptionCannotEscapeIntoJniOrStopFollowingEvents() {
    ArrayDeque<Runnable> platform = new ArrayDeque<>();
    List<RuntimeException> errors = new ArrayList<>();
    List<String> events = new ArrayList<>();
    PeerConnectionEventDispatcher dispatcher = new PeerConnectionEventDispatcher(
        platform::add, errors::add);
    dispatcher.dispatch(() -> { throw new IllegalStateException("RtpReceiver has been disposed."); });
    dispatcher.dispatch(() -> events.add("replacement"));
    while (!platform.isEmpty()) platform.remove().run();
    assertEquals(1, errors.size());
    assertEquals("RtpReceiver has been disposed.", errors.get(0).getMessage());
    assertEquals(java.util.Arrays.asList("replacement"), events);
  }
}
