// Connections to devices on the shop network (192.168.x.x and the like).
//
// On Android, a Wi-Fi with no internet before logging in (the hotspot) is not used for the app's traffic: Android
// sends it over mobile data, where the router cannot be reached. So these connections are made on the Wi-Fi itself
// (MainActivity: lanTunnel, lanProbe). Elsewhere (Windows, or no Wi-Fi) they are ordinary connections.
import 'dart:io';

import 'package:flutter/services.dart';

const _native = MethodChannel('hv/native');

bool _private(String ip) {
  final p = ip.split('.').map(int.tryParse).toList();
  if (p.length != 4 || p.any((x) => x == null || x < 0 || x > 255)) return false;
  final a = p[0]!, b = p[1]!;
  return a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) || (a == 100 && b >= 64 && b <= 127);
}

/// A plain TCP connection to [host]:[port], made on the Wi-Fi when [host] is on the shop network.
Future<Socket> lanConnect(String host, int port, Duration timeout) async {
  if (Platform.isAndroid && _private(host)) {
    int? local;
    try {
      local = await _native.invokeMethod<int>('lanTunnel', {'host': host, 'port': port, 'ms': timeout.inMilliseconds})
          .timeout(timeout + const Duration(seconds: 3));
    } on PlatformException catch (e) {
      throw SocketException(e.message ?? 'Could not connect', address: InternetAddress.tryParse(host), port: port);
    } on MissingPluginException {
      local = null;
    }
    if (local != null) return Socket.connect(InternetAddress.loopbackIPv4, local, timeout: const Duration(seconds: 5));
  }
  return Socket.connect(host, port, timeout: timeout);
}

/// Is [port] open on [host]? Checked on the Wi-Fi when [host] is on the shop network.
Future<bool> lanProbe(String host, int port, int ms) async {
  if (Platform.isAndroid && _private(host)) {
    try {
      final r = await _native.invokeMethod<bool>('lanProbe', {'host': host, 'port': port, 'ms': ms})
          .timeout(Duration(milliseconds: ms + 3000));
      if (r != null) return r;
    } catch (_) {}
  }
  try {
    final s = await Socket.connect(host, port, timeout: Duration(milliseconds: ms));
    s.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// For HttpClient.connectionFactory: web pages of devices on the shop network, reached on the Wi-Fi.
Future<ConnectionTask<Socket>> lanHttp(Uri uri, Duration timeout) async {
  final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
  Future<Socket> open() async {
    final s = await lanConnect(uri.host, port, timeout);
    if (uri.scheme != 'https') return s;
    return SecureSocket.secure(s, host: uri.host, onBadCertificate: (_) => true);
  }
  return ConnectionTask.fromSocket(open(), () {});
}
