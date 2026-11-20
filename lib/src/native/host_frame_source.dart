import 'package:webrtc_interface/webrtc_interface.dart';

import 'media_stream_impl.dart';
import 'utils.dart';

class HostFrameSource {
  HostFrameSource._();

  static Future<MediaStream> createCustomVideoTrack() async {
    final response = await WebRTC.invokeMethod('createCustomVideoTrack');
    if (response == null) {
      throw Exception('createCustomVideoTrack returned null');
    }
    final stream = MediaStreamNative(response['streamId'], 'local');
    stream.setMediaTracks([], response['videoTracks'] ?? []);
    return stream;
  }

  static Future<void> startHostShmCapture(String trackId) async {
    await WebRTC.invokeMethod('startHostShmCapture', <String, dynamic>{
      'trackId': trackId,
    });
  }

  static Future<void> stopHostShmCapture() async {
    await WebRTC.invokeMethod('stopHostShmCapture');
  }
}
