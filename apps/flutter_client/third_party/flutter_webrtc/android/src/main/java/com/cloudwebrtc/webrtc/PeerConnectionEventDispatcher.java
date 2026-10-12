package com.cloudwebrtc.webrtc;

import java.util.concurrent.Executor;
import java.util.function.Consumer;
import java.util.function.Supplier;

/** Keep track snapshots on the platform thread, outside native JNI callbacks. */
final class PeerConnectionEventDispatcher {
  private final Executor executor;
  private final Consumer<RuntimeException> onError;
  private volatile boolean closed;

  PeerConnectionEventDispatcher(Executor executor, Consumer<RuntimeException> onError) {
    this.executor = executor;
    this.onError = onError;
  }

  void dispatch(Runnable event) {
    executor.execute(() -> {
      if (closed) return;
      try {
        event.run();
      } catch (RuntimeException error) {
        // A Java exception escaping a WebRTC observer aborts the whole process.
        onError.accept(error);
      }
    });
  }

  void snapshot(Supplier<Runnable> snapshot) {
    if (closed) return;
    try {
      // Stream wrappers can be disposed as soon as the native callback returns.
      // Read their metadata now, then queue only the platform operation.
      dispatch(snapshot.get());
    } catch (RuntimeException error) {
      onError.accept(error);
    }
  }

  void close() { closed = true; }
}
