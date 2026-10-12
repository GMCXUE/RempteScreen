import 'package:livekit_client/livekit_client.dart';

/// Preserve the Android factory choice when LiveKit fills server ICE/TURN options.
class FriendRTCConfiguration extends RTCConfiguration {
  const FriendRTCConfiguration(
      {super.iceCandidatePoolSize,
      super.iceServers,
      super.iceTransportPolicy,
      super.encodedInsertableStreams,
      super.isDscpEnabled});
  @override
  Map<String, dynamic> toMap() => {...super.toMap(), 'friendCallAudio': true};
  @override
  RTCConfiguration copyWith(
          {int? iceCandidatePoolSize,
          List<RTCIceServer>? iceServers,
          RTCIceTransportPolicy? iceTransportPolicy,
          bool? encodedInsertableStreams,
          bool? isDscpEnabled}) =>
      FriendRTCConfiguration(
          iceCandidatePoolSize:
              iceCandidatePoolSize ?? this.iceCandidatePoolSize,
          iceServers: iceServers ?? this.iceServers,
          iceTransportPolicy: iceTransportPolicy ?? this.iceTransportPolicy,
          encodedInsertableStreams:
              encodedInsertableStreams ?? this.encodedInsertableStreams,
          isDscpEnabled: isDscpEnabled ?? this.isDscpEnabled);
}

class FriendAudioCaptureOptions extends AudioCaptureOptions {
  const FriendAudioCaptureOptions()
      : super(
            echoCancellation: true,
            noiseSuppression: true,
            autoGainControl: true,
            voiceIsolation: true);
  @override
  Map<String, dynamic> toMediaConstraintsMap() =>
      {...super.toMediaConstraintsMap(), 'friendCallAudio': true};
}
