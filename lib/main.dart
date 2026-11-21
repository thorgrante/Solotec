import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bridge.dart';
import 'config.dart';
import 'connector.dart';
import 'web_shell.dart';

const native = MethodChannel('hv/native');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final p = await SharedPreferences.getInstance();
  var install = p.getString('hv.install');
  if (install == null || install.isEmpty) {
    final r = Random.secure();
    install = List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    await p.setString('hv.install', install);
  }
  final device = await _deviceName();
  if (Platform.isAndroid) {
    try {
      await native.invokeMethod('multicast', true); // let router announcements in over Wi-Fi
    } catch (_) {}
  }
  final connector = Connector(device: device, version: appVersion);
  await connector.start();
  final bridge = Bridge(connector: connector, platform: Platform.isWindows ? 'windows' : 'android', version: appVersion, device: device, install: install);
  runApp(HvApp(bridge: bridge, server: p.getString('hv.server') ?? defaultServer));
}

Future<String> _deviceName() async {
  if (Platform.isAndroid) {
    try {
      final n = await native.invokeMethod<String>('deviceName');
      if (n != null && n.trim().isNotEmpty) return n.trim();
    } catch (_) {}
    return 'Android phone';
  }
  try {
    final h = Platform.localHostname;
    if (h.isNotEmpty) return h;
  } catch (_) {}
  return 'Windows computer';
}

class HvApp extends StatelessWidget {
  const HvApp({super.key, required this.bridge, required this.server});
  final Bridge bridge;
  final String server;

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF7F19FF);
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: seed), useMaterial3: true),
      darkTheme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark), useMaterial3: true),
      home: WebShell(bridge: bridge, server: server),
    );
  }
}
