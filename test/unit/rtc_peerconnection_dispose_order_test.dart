import 'package:flutter/services.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_webrtc/src/native/rtc_peerconnection_impl.dart';

import 'ensure_test_binding.dart';

void main() {
  ensureTestBinding();

  const peerConnectionId = 'pc-order-test';
  final methodChannel = MethodChannel('FlutterWebRTC.Method');
  final eventChannel =
      MethodChannel('FlutterWebRTC/peerConnectionEvent$peerConnectionId');

  final calls = <String>[];

  setUp(() {
    calls.clear();
    methodChannel.setMockMethodCallHandler((MethodCall methodCall) async {
      calls.add(methodCall.method);
      return null;
    });
    eventChannel.setMockMethodCallHandler((MethodCall methodCall) async {
      calls.add('event:${methodCall.method}');
      return null;
    });
  });

  tearDown(() {
    methodChannel.setMockMethodCallHandler(null);
    eventChannel.setMockMethodCallHandler(null);
  });

  test('close then dispose cancels the event subscription before disposing',
      () async {
    final pc = RTCPeerConnectionNative(peerConnectionId, {});

    // Let the constructor's subscription reach the platform side.
    await Future<void>.delayed(Duration.zero);

    await pc.close();
    await pc.dispose();

    // Both calls are recorded synchronously by the mock handlers while
    // dispose() is awaited. Yield once more anyway so nothing is left pending.
    await Future<void>.delayed(Duration.zero);

    expect(calls, contains('peerConnectionClose'));
    expect(calls, contains('event:listen'));
    expect(calls, contains('event:cancel'));
    expect(calls, contains('peerConnectionDispose'));

    expect(
        calls.indexOf('event:listen'), lessThan(calls.indexOf('event:cancel')));
    expect(calls.indexOf('event:cancel'),
        lessThan(calls.indexOf('peerConnectionDispose')));
  });
}
