package com.cloudwebrtc.webrtc;

import java.util.HashMap;
import java.util.Map;

/**
 * Thread-safe registry of the current remote track object for each track id.
 *
 * A Unified Plan renegotiation may replace the Java track wrapper while
 * preserving its WebRTC track id. Late removal of the previous MediaStream
 * must not remove the replacement from the registry.
 */
final class RemoteTrackRegistry<T> {
  private final Map<String, T> tracks = new HashMap<>();
  private final Map<String, String> owners = new HashMap<>();

  synchronized void put(String trackId, T track) {
    tracks.put(trackId, track);
    owners.remove(trackId);
  }

  synchronized void put(String trackId, T track, String receiverId) {
    tracks.put(trackId, track);
    owners.put(trackId, receiverId);
  }

  synchronized boolean removeOwned(String trackId, String receiverId) {
    if (!receiverId.equals(owners.get(trackId))) return false;
    tracks.remove(trackId);
    owners.remove(trackId);
    return true;
  }

  synchronized T get(String trackId) {
    return tracks.get(trackId);
  }

  synchronized boolean remove(String trackId, T track) {
    if (tracks.get(trackId) != track) {
      return false;
    }
    tracks.remove(trackId);
    owners.remove(trackId);
    return true;
  }

  synchronized void clear() {
    tracks.clear();
    owners.clear();
  }
}
