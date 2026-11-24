// Finding routers on the network this phone or computer is on. The same results as the Windows connector
// (connector/discovery.js on the server): MikroTik announcements (MNDP, UDP 5678), a sweep of the RouterOS API and
// web ports on this device's own private networks (each as a /24, at most 4), the device web page, and on Windows the
// ARP table for MAC addresses.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'lan.dart';

bool privateIp(String ip) {
  final m = RegExp(r'^(\d+)\.(\d+)\.(\d+)\.(\d+)$').firstMatch(ip);
  if (m == null) return false;
  final a = int.parse(m.group(1)!), b = int.parse(m.group(2)!);
  return a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) || (a == 100 && b >= 64 && b <= 127);
}

const _oui = <String, List<String>>{
  'MikroTik': ['000C42', '4C5E0C', '64D154', '6C3B6B', 'B869F4', 'CC2DE0', 'D4CA6D', 'E48D8C', '2CC81B', '744D28', 'DC2C6E', '488F5A', '085531', '18FD74', 'C4AD34', '48A98A', '789A18', 'F41E57', 'D401C3', '04F41C'],
  'Grandstream': ['000B82', 'C074AD', 'EC74D7'],
  'Ruijie': ['00749C', '58696C', 'C0B8E6', '800588', '14144B', '00D0F8'],
  'TP-Link': ['50C7BF', '98DAC4', 'F4F26D', 'C04A00', '14CC20', '60E327', 'EC086B', 'A0F3C1', '54AF97', '30B5C2', 'B0BE76', '18A6F7', '1C3BF3', '98254A', '5C628B', '68FF7B', '3C846A', '10FEED', '647002', 'E848B8', '74DA88', '003192', '8416F9', '90F652', 'AC84C6', 'B04E26', 'C006C3', 'D807B6', 'E4C32A'],
};
final _words = <(String, RegExp)>[
  ('MikroTik', RegExp(r'mikrotik|routeros|webfig|routerboard', caseSensitive: false)),
  ('Grandstream', RegExp(r'grandstream|\bgwn\d|gdms', caseSensitive: false)),
  ('Ruijie', RegExp(r'ruijie|reyee|\beweb\b|\brg-[a-z0-9]', caseSensitive: false)),
  ('TP-Link', RegExp(r'tp-?link|omada|tplinkwifi|\btl-[a-z]{2,}\d', caseSensitive: false)),
];

String normMac(String? m) {
  final h = (m ?? '').replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
  if (h.length != 12) return '';
  return [for (var i = 0; i < 12; i += 2) h.substring(i, i + 2)].join(':');
}

String ouiVendor(String? mac) {
  final p = normMac(mac).replaceAll(':', '');
  if (p.length < 6) return '';
  for (final e in _oui.entries) {
    if (e.value.contains(p.substring(0, 6))) return e.key;
  }
  return '';
}

String wordsVendor(String t) {
  for (final w in _words) {
    if (w.$2.hasMatch(t)) return w.$1;
  }
  return '';
}

String _kind(String vendor, String text) {
  if (RegExp(r'\b(eap\d|gwn76|access point|\bap\b|wireless ap)', caseSensitive: false).hasMatch(text)) return 'Access point';
  if (RegExp(r'\bswitch\b|\bsg\d|\bcss\d|\bcrs\d', caseSensitive: false).hasMatch(text)) return 'Switch';
  if (vendor == 'MikroTik' || RegExp(r'router|gateway|\bhap\b|\brb\d|\bccr\d|\ber\d{3,4}|\beg\d', caseSensitive: false).hasMatch(text)) return 'Router';
  return vendor.isNotEmpty ? 'Network device' : 'Unknown';
}

class LocalNet {
  LocalNet(this.iface, this.self, this.prefix);
  final String iface, self, prefix;
  String get subnet => '${prefix}0/24';
}

Future<List<LocalNet>> localNets() async {
  final out = <LocalNet>[];
  try {
    for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false)) {
      for (final a in i.addresses) {
        if (!privateIp(a.address)) continue;
        final p = a.address.split('.');
        final prefix = '${p[0]}.${p[1]}.${p[2]}.';
        if (!out.any((n) => n.prefix == prefix)) out.add(LocalNet(i.name, a.address, prefix));
      }
    }
  } catch (_) {}
  return out.take(4).toList();
}

Future<bool> tryPort(String host, int port, int ms) => lanProbe(host, port, ms);

Future<void> _pool<T>(List<T> items, int n, Future<void> Function(T) fn, bool Function() stop) async {
  var i = 0;
  Future<void> worker() async {
    while (i < items.length && !stop()) {
      final x = items[i++];
      await fn(x);
    }
  }

  await Future.wait(List.generate(n < items.length ? n : items.length, (_) => worker()));
}

/// The device web page: title, server header, a little of the text.
Future<Map<String, String>?> webPage(String ip, int port) async {
  final c = HttpClient()
    ..connectionTimeout = const Duration(milliseconds: 1800)
    ..badCertificateCallback = ((cert, host, p) => true)
    ..connectionFactory = ((uri, proxyHost, proxyPort) => lanHttp(uri, const Duration(milliseconds: 1800)));
  try {
    final req = await c.getUrl(Uri(scheme: port == 443 ? 'https' : 'http', host: ip, port: port, path: '/')).timeout(const Duration(milliseconds: 1800));
    req.followRedirects = false;
    req.headers.set('User-Agent', 'hv-app');
    final res = await req.close().timeout(const Duration(milliseconds: 2500));
    final sb = StringBuffer();
    await for (final chunk in res.transform(const Utf8Decoder(allowMalformed: true)).timeout(const Duration(milliseconds: 2500))) {
      sb.write(chunk);
      if (sb.length > 8000) break;
    }
    final body = sb.toString();
    final title = RegExp(r'<title[^>]*>([^<]{0,120})', caseSensitive: false).firstMatch(body)?.group(1)?.trim() ?? '';
    return {'title': title, 'server': res.headers.value('server') ?? '', 'location': res.headers.value('location') ?? '', 'text': body.length > 8000 ? body.substring(0, 8000) : body};
  } catch (_) {
    return null;
  } finally {
    c.close(force: true);
  }
}

/// Windows only: IP and MAC of the devices this computer has talked to.
Future<List<(String, String)>> arpTable() async {
  if (!Platform.isWindows) return [];
  try {
    final r = await Process.run('arp', ['-a']).timeout(const Duration(seconds: 5));
    final out = <(String, String)>[];
    for (final l in r.stdout.toString().split(RegExp(r'\r?\n'))) {
      final m = RegExp(r'(\d+\.\d+\.\d+\.\d+)\s+(([0-9a-fA-F]{2}-){5}[0-9a-fA-F]{2})').firstMatch(l);
      if (m == null) continue;
      final mac = normMac(m.group(2));
      if (mac.isNotEmpty && !RegExp(r'^FF:FF:FF|^01:00:5E|^33:33').hasMatch(mac)) out.add((m.group(1)!, mac));
    }
    return out;
  } catch (_) {
    return [];
  }
}

class MndpInfo {
  MndpInfo({required this.mac, this.ip = '', this.identity = '', this.version = '', this.board = '', this.iface = ''});
  final String mac;
  String ip, identity, version, board, iface;
  DateTime at = DateTime.now();
}

MndpInfo? parseMndp(Uint8List b) {
  if (b.length < 8) return null;
  final bd = ByteData.sublistView(b);
  var o = 4;
  String? mac, identity, version, board, iface, ip;
  while (o + 4 <= b.length) {
    final t = bd.getUint16(o), l = bd.getUint16(o + 2);
    o += 4;
    if (o + l > b.length) break;
    final v = b.sublist(o, o + l);
    o += l;
    final s = utf8.decode(v, allowMalformed: true);
    if (t == 1 && l == 6) {
      mac = v.map((x) => x.toRadixString(16).padLeft(2, '0')).join(':').toUpperCase();
    } else if (t == 5) {
      identity = s;
    } else if (t == 7) {
      version = s;
    } else if (t == 12) {
      board = s;
    } else if (t == 16) {
      iface = s;
    } else if (t == 17 && l == 4) {
      ip = v.join('.');
    }
  }
  if (mac == null) return null;
  return MndpInfo(mac: mac, ip: ip ?? '', identity: identity ?? '', version: version ?? '', board: board ?? '', iface: iface ?? '');
}

/// Listens for MikroTik announcements while the app runs. Routers announce themselves about every minute, and
/// answer straight away when asked.
class MndpListener {
  RawDatagramSocket? _s;
  final Map<String, MndpInfo> seen = {};

  Future<void> start() async {
    if (_s != null) return;
    try {
      final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 5678, reuseAddress: true);
      s.broadcastEnabled = true;
      s.listen((ev) {
        if (ev != RawSocketEvent.read) return;
        final d = s.receive();
        if (d == null) return;
        final m = parseMndp(d.data);
        if (m == null) return;
        if (m.ip.isEmpty) m.ip = d.address.address;
        seen[m.mac] = m;
      });
      _s = s;
      ask();
    } catch (_) {
      // Another program may hold the port; the sweep still finds routers by their API port.
    }
  }

  void ask() {
    try {
      _s?.send(Uint8List(4), InternetAddress('255.255.255.255'), 5678);
    } catch (_) {}
  }

  Iterable<MndpInfo> fresh() => seen.values.where((m) => DateTime.now().difference(m.at) < const Duration(minutes: 15));
}

class _Dev {
  _Dev(this.ip);
  final String ip;
  final List<String> methods = [];
  String mac = '', iface = '', mndpIdentity = '', mndpBoard = '', mndpVersion = '';
  String webTitle = '', webServer = '', webLocation = '', webText = '';
  bool mndp = false, api = false, apiSsl = false, web = false, webSsl = false;
  void method(String m) {
    if (!methods.contains(m)) methods.add(m);
  }
}

typedef Progress = void Function(int pct, String phase, List<Map<String, dynamic>> found);

class ScanResult {
  ScanResult(this.routers, this.stopped, this.nets, this.seconds);
  final List<Map<String, dynamic>> routers;
  final bool stopped;
  final List<String> nets;
  final double seconds;
}

Future<ScanResult> scan(MndpListener mndp, {required Progress progress, required bool Function() stop}) async {
  final started = DateTime.now();
  final nets = await localNets();
  final dev = <String, _Dev>{};
  _Dev put(String ip) => dev.putIfAbsent(ip, () => _Dev(ip));
  LocalNet? netOf(String ip) {
    for (final n in nets) {
      if (ip.startsWith(n.prefix)) return n;
    }
    return null;
  }

  Map<String, dynamic>? finish(_Dev d) {
    final text = [d.mndpBoard, d.webTitle, d.webServer, d.webLocation, d.webText].where((x) => x.isNotEmpty).join(' ');
    var vendor = d.mndp ? 'MikroTik' : wordsVendor([d.webTitle, d.webServer, d.webLocation, d.webText].join(' '));
    var from = d.mndp ? 'MNDP' : (vendor.isNotEmpty ? 'web page' : '');
    if (vendor.isEmpty && (d.api || d.apiSsl)) {
      vendor = 'MikroTik';
      from = 'RouterOS API port';
    }
    final likely = ouiVendor(d.mac);
    if (vendor.isEmpty && likely.isNotEmpty) {
      vendor = likely;
      from = 'MAC address (likely)';
    }
    if (vendor.isEmpty) return null; // phones, computers and printers are not listed
    final n = netOf(d.ip);
    final model = d.mndpBoard.isNotEmpty ? d.mndpBoard : (RegExp(r'\b(RG-|EAP|GWN|TL-)[A-Za-z0-9-]+').firstMatch(d.webTitle)?.group(0) ?? '');
    return {
      'ip': d.ip, 'mac': d.mac, 'identity': d.mndpIdentity, 'vendor': vendor, 'vendorFrom': from, 'model': model, 'version': d.mndpVersion,
      'type': _kind(vendor, text), 'iface': d.iface.isNotEmpty ? d.iface : (n?.iface ?? ''), 'subnet': n?.subnet ?? '',
      'reachable': d.api || d.apiSsl || d.web || d.webSsl || d.mndp, 'api': d.api, 'apiSsl': d.apiSsl, 'web': d.web || d.webSsl, 'methods': d.methods,
    };
  }

  List<Map<String, dynamic>> list() => dev.values.map(finish).whereType<Map<String, dynamic>>().toList();
  final where = nets.isEmpty ? 'this network' : nets.map((n) => n.subnet).join(', ');

  progress(2, 'Asking MikroTik routers to announce themselves', []);
  mndp.ask();
  await Future<void>.delayed(const Duration(milliseconds: 1500));
  void addMndp() {
    for (final m in mndp.fresh()) {
      if (m.ip.isEmpty || (nets.isNotEmpty && netOf(m.ip) == null)) continue;
      final d = put(m.ip)
        ..mac = m.mac
        ..mndp = true
        ..mndpIdentity = m.identity
        ..mndpBoard = m.board
        ..mndpVersion = m.version
        ..iface = m.iface;
      d.method('MNDP');
    }
  }

  addMndp();
  // 1. sweep: who answers on the management ports
  final hosts = <String>[for (final n in nets) for (var i = 1; i < 255; i++) if ('${n.prefix}$i' != n.self) '${n.prefix}$i'];
  var k = 0;
  progress(5, 'Scanning $where', list());
  await _pool<String>(hosts, 64, (ip) async {
    final api = await tryPort(ip, 8728, 600);
    final web80 = await tryPort(ip, 80, 500);
    final apiSsl = api ? false : await tryPort(ip, 8729, 300);
    if (api || apiSsl || web80) {
      final d = put(ip)
        ..api = api
        ..apiSsl = apiSsl
        ..web = web80;
      d.method('TCP');
    }
    if (++k % 16 == 0) progress(5 + (k * 55 ~/ (hosts.isEmpty ? 1 : hosts.length)), 'Scanning $where', list());
  }, stop);
  addMndp(); // late answers
  if (stop()) return ScanResult(list(), true, nets.map((n) => n.subnet).toList(), DateTime.now().difference(started).inMilliseconds / 1000);
  // 2. MAC addresses (Windows)
  progress(62, 'Reading MAC addresses', list());
  for (final a in await arpTable()) {
    if (netOf(a.$1) != null || dev.containsKey(a.$1)) {
      final d = put(a.$1);
      if (d.mac.isEmpty) d.mac = a.$2;
      d.method('ARP');
    }
  }
  // 3. details: the web page of devices that could be network equipment
  final cand = dev.values.where((d) => d.web || !(d.api || d.apiSsl || d.mndp)).map((d) => d.ip).take(64).toList();
  var j = 0;
  progress(70, 'Identifying devices', list());
  await _pool<String>(cand, 12, (ip) async {
    final d = dev[ip]!;
    Map<String, String>? w;
    if (d.web) {
      w = await webPage(ip, 80);
      if (w != null) d.method('HTTP');
    } else if (await tryPort(ip, 443, 500)) {
      w = await webPage(ip, 443);
      if (w != null) {
        d.webSsl = true;
        d.method('HTTPS');
      }
    }
    if (w != null) {
      d.webTitle = w['title']!;
      d.webServer = w['server']!;
      d.webLocation = w['location']!;
      d.webText = w['text']!;
    }
    progress(70 + (++j * 28 ~/ (cand.isEmpty ? 1 : cand.length)), 'Identifying devices', list());
  }, stop);
  final out = list();
  progress(100, 'Done', out);
  return ScanResult(out, stop(), nets.map((n) => n.subnet).toList(), DateTime.now().difference(started).inMilliseconds / 1000);
}

/// One device: is it there, and what answers (no password needed).
Future<Map<String, dynamic>> probe(String ip) async {
  final r = await Future.wait([tryPort(ip, 8728, 1500), tryPort(ip, 8729, 1500), tryPort(ip, 80, 1500), tryPort(ip, 443, 1500)]);
  return {'ip': ip, 'reachable': r.any((x) => x), 'api': r[0], 'apiSsl': r[1], 'web': r[2] || r[3]};
}
