class HostFrameSource {
  HostFrameSource._();

  static Future<dynamic> createCustomVideoTrack() async {
    throw UnsupportedError('HostFrameSource is Windows-only');
  }

  static Future<void> startHostShmCapture(String trackId) async {}

  static Future<void> stopHostShmCapture() async {}
}
