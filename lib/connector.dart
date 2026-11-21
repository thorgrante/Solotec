// This app as the "site connector": while it is open on the router's network, the website reaches the router
// through it. The server side is site.js (POST /api/connector/self gives this install its key; the app then polls
// /api/portal/connector/poll and answers its jobs: scan, stop, probe, open, run, close). The website never needs
// to see the router from the internet, and nothing is installed on the router.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'discovery.dart';
import 'routeros.dart';

class Link {
  Link({required this.server, required this.branch, required this.id, required this.key});
  final String server; // https://example.com (origin)
  final int branch;
  final int id;
  final String key;
  Map<String, dynamic> toJson() => {'server': server, 'branch': branch, 'id': id, 'key': key};
  static Link? fromJson(Object? j) {
    if (j is! Map) return null;
    final s = j['server'], b = j['branch'], i = j['id'], k = j['key'];
    if (s is! String || b is! int || i is! int || k is! String) return null;
    return Link(server: s, branch: b, id: i, key: k);
  }
}

class Connector {
  Connector({required this.device, required this.version});
  final String device;
  final String version;
  final MndpListener mndp = MndpListener();
  final Map<String, _Line> _lines = {}; // key -> line
  List<Link> _links = [];
  static const _prefKey = 'hv.links';

  Future<void> start() async {
    final p = await SharedPreferences.getInstance();
    try {
      _links = (jsonDecode(p.getString(_prefKey) ?? '[]') as List).map(Link.fromJson).whereType<Link>().toList();
    } catch (_) {
      _links = [];
    }
    await mndp.start();
    for (final l in _links) {
      _open(l);
    }
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_prefKey, jsonEncode(_links.map((l) => l.toJson()).toList()));
  }

  Link? find(String server, int branch) {
    for (final l in _links) {
      if (l.server == server && l.branch == branch) return l;
    }
    return null;
  }

  Future<Link> attach(String server, int branch, int id, String key) async {
    await forget(server, branch);
    final l = Link(server: server, branch: branch, id: id, key: key);
    _links.add(l);
    await _save();
    await mndp.start();
    _open(l);
    return l;
  }

  Future<void> forget(String server, int branch) async {
    final old = find(server, branch);
    if (old == null) return;
    _lines.remove(old.key)?.stop();
    _links.remove(old);
    await _save();
  }

  void _open(Link l) {
    if (_lines.containsKey(l.key)) return;
    final line = _Line(this, l);
    _lines[l.key] = line;
    line.run();
  }

  /// The server said this key is no longer valid (removed in the app, or unknown).
  Future<void> _dropped(Link l) async {
    _lines.remove(l.key);
    _links.remove(l);
    await _save();
  }
}

class _Session {
  _Session(this.c);
  final RouterOS c;
  DateTime used = DateTime.now();
}

/// One line to the website for one branch.
class _Line {
  _Line(this.owner, this.link);
  final Connector owner;
  final Link link;
  bool _stopped = false;
  final HttpClient _http = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  final List<Map<String, dynamic>> _done = [];
  final Map<String, _Session> _sessions = {};
  final Set<String> _stopScan = {};
  int _sid = 0;
  Map<String, dynamic>? _scan, _sentScan;
  List<Map<String, dynamic>> _found = [];
  String _lastFound = '';
  bool _report = true;
  Future<void>? _quick;
  DateTime _lastKick = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _idle;

  void stop() {
    _stopped = true;
    _idle?.cancel();
    for (final s in _sessions.values) {
      s.c.close();
    }
    _sessions.clear();
    _http.close(force: true);
  }

  Future<Map<String, dynamic>> _post(Map<String, dynamic> body, Duration timeout) async {
    final req = await _http.postUrl(Uri.parse('${link.server}/api/portal/connector/poll')).timeout(timeout);
    req.headers.contentType = ContentType.json;
    req.add(utf8.encode(jsonEncode(body)));
    final res = await req.close().timeout(timeout);
    final text = await res.transform(utf8.decoder).join().timeout(timeout);
    Map<String, dynamic> j = {};
    try {
      final d = jsonDecode(text);
      if (d is Map<String, dynamic>) j = d;
    } catch (_) {}
    if (res.statusCode == 401 || res.statusCode == 410) throw _Gone();
    if (res.statusCode >= 400) throw HttpException('${j['error'] ?? 'The website answered ${res.statusCode}.'}');
    return j;
  }

  Map<String, dynamic> _base() => {'k': link.key, 'pc': owner.device, 'version': 'app:${owner.version}'};

  Future<void> run() async {
    _idle = Timer.periodic(const Duration(seconds: 15), (_) {
      final now = DateTime.now();
      _sessions.removeWhere((k, s) {
        final old = now.difference(s.used) > const Duration(minutes: 2);
        if (old) s.c.close();
        return old;
      });
      _report = true; // keep "what is on this network" fresh on the server
    });
    var wait = 0;
    while (!_stopped) {
      final body = _base();
      body['done'] = List<Map<String, dynamic>>.from(_done);
      _done.clear();
      final f = jsonEncode(_routers());
      if (_report || f != _lastFound) {
        body['found'] = jsonDecode(f);
        _lastFound = f;
        _report = false;
      }
      if (_scan != null && !identical(_scan, _sentScan)) {
        body['scan'] = _scan;
        _sentScan = _scan;
      }
      try {
        final r = await _post(body, const Duration(seconds: 35));
        wait = 0;
        _jobs(r['jobs']);
      } on _Gone {
        await owner._dropped(link);
        stop();
        return;
      } catch (_) {
        _done.insertAll(0, (body['done'] as List).cast<Map<String, dynamic>>());
        wait = wait == 0 ? 1 : (wait * 2 > 30 ? 30 : wait * 2);
        await Future<void>.delayed(Duration(seconds: wait));
      }
    }
  }

  List<Map<String, dynamic>> _routers() {
    if (_found.isNotEmpty) return _found;
    // Before any scan: the routers that announced themselves.
    return owner.mndp.fresh().map((m) => <String, dynamic>{
          'ip': m.ip, 'mac': m.mac, 'identity': m.identity, 'vendor': 'MikroTik', 'vendorFrom': 'MNDP', 'model': m.board, 'version': m.version,
          'type': 'Router', 'iface': m.iface, 'reachable': true, 'api': false, 'apiSsl': false, 'web': false, 'methods': ['MNDP'],
        }).toList();
  }

  /// Results go back at once, on a short extra poll.
  void _kick() {
    if (_stopped || _quick != null) return;
    if (_done.isEmpty && identical(_scan, _sentScan)) return;
    final body = _base()..['quick'] = true;
    final d = List<Map<String, dynamic>>.from(_done);
    _done.clear();
    body['done'] = d;
    final sc = _scan;
    if (sc != null && !identical(sc, _sentScan)) {
      body['scan'] = sc;
      _sentScan = sc;
    }
    _quick = _post(body, const Duration(seconds: 15)).then((r) => _jobs(r['jobs'])).catchError((Object _) {
      _done.insertAll(0, d);
    }).whenComplete(() {
      _quick = null;
      if (_done.isNotEmpty || !identical(_scan, _sentScan)) _kick();
    });
  }

  void _jobs(Object? jobs) {
    if (jobs is! List) return;
    for (final j in jobs) {
      if (j is! Map) continue;
      final job = Map<String, dynamic>.from(j);
      _handle(job).then((result) => <String, dynamic>{'id': job['id'], 'ok': true, 'result': result}, onError: (Object e) {
        final msg = e is RouterError ? e.message : e.toString();
        return <String, dynamic>{'id': job['id'], 'ok': false, 'error': msg, if ((e is RouterError && e.kind == 'auth') || msg.startsWith('Login failed')) 'kind': 'auth'};
      }).then((r) {
        _done.add(r);
        _kick();
      });
    }
  }

  static bool _allowedPort(Object? p) => const [8728, 8729, 80, 443].contains(p is int ? p : int.tryParse('$p'));

  Future<Map<String, dynamic>> _handle(Map<String, dynamic> j) async {
    final op = j['op'];
    if (op == 'discover' || op == 'scan') {
      final id = '${j['scanId'] ?? 'scan-${DateTime.now().millisecondsSinceEpoch}'}';
      _scan = {'id': id, 'pct': 0, 'phase': 'Starting', 'found': <Map<String, dynamic>>[], 'done': false};
      final r = await scan(owner.mndp, stop: () => _stopScan.contains(id) || _stopped, progress: (pct, phase, found) {
        _scan = {'id': id, 'pct': pct, 'phase': phase, 'found': found, 'done': false};
        if (DateTime.now().difference(_lastKick) > const Duration(milliseconds: 700)) {
          _lastKick = DateTime.now();
          _kick();
        }
      });
      _found = r.routers;
      _scan = {'id': id, 'pct': 100, 'phase': r.stopped ? 'Stopped' : 'Done', 'found': r.routers, 'done': true, 'stopped': r.stopped, 'nets': r.nets};
      _stopScan.remove(id);
      return {'routers': r.routers, 'stopped': r.stopped, 'nets': r.nets, 'seconds': r.seconds};
    }
    if (op == 'stop') {
      _stopScan.add('${j['scanId']}');
      return {};
    }
    if (op == 'probe') {
      final ip = '${j['ip']}';
      if (!privateIp(ip)) throw RouterError('Only devices on this network can be checked.');
      return probe(ip);
    }
    if (op == 'open') {
      final host = '${j['host']}';
      if (!privateIp(host) || !_allowedPort(j['port'])) {
        throw RouterError('This app only connects to routers on the network it is on ($host:${j['port']} is not).');
      }
      if (j['protocol'] == 'rest') {
        throw RouterError('The app connects with the RouterOS API. Choose API (port 8728) in Advanced, then try again.');
      }
      final port = j['port'] is int ? j['port'] as int : int.parse('${j['port']}');
      final ms = (j['timeout'] is int ? j['timeout'] as int : 8000).clamp(1000, 20000).toInt();
      final c = RouterOS(host: host, port: port, tls: j['tls'] == true, user: '${j['user'] ?? ''}', password: '${j['password'] ?? ''}', timeout: Duration(milliseconds: ms));
      await c.connect();
      final sid = 's${++_sid}';
      _sessions[sid] = _Session(c);
      return {'sid': sid};
    }
    final s = _sessions['${j['sid']}'];
    if (op == 'close') {
      if (s != null) {
        s.c.close();
        _sessions.remove('${j['sid']}');
      }
      return {};
    }
    if (op == 'run') {
      if (s == null) throw RouterError('Not connected.');
      s.used = DateTime.now();
      final words = j['words'];
      if (words is! List || words.any((w) => w is! String)) throw RouterError('Bad command.');
      final r = await s.c.run(words.cast<String>());
      return {'rows': r.rows, 'done': r.done};
    }
    throw RouterError('Unknown job.');
  }
}

class _Gone implements Exception {}
