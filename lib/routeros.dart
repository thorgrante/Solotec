// RouterOS API client (TCP 8728, or 8729 with TLS). The same wire format and login as the server's mikrotik.js,
// so the website can drive a router through this app exactly as it does through the Windows connector.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class RouterReply {
  RouterReply(this.rows, this.done);
  final List<Map<String, String>> rows;
  final Map<String, String> done;
}

class RouterError implements Exception {
  RouterError(this.message, {this.kind});
  final String message;
  final String? kind;
  @override
  String toString() => message;
}

List<int> encodeLength(int n) {
  if (n < 0x80) return [n];
  if (n < 0x4000) {
    n |= 0x8000;
    return [(n >> 8) & 255, n & 255];
  }
  if (n < 0x200000) {
    n |= 0xC00000;
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  if (n < 0x10000000) {
    n |= 0xE0000000;
    return [(n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  return [0xF0, (n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255];
}

Uint8List encodeSentence(List<String> words) {
  final b = BytesBuilder(copy: false);
  for (final w in words) {
    final bytes = utf8.encode(w);
    b.add(encodeLength(bytes.length));
    b.add(bytes);
  }
  b.addByte(0);
  return b.toBytes();
}

/// Reads one word at [off]. Returns null when the buffer does not hold the whole word yet.
({String word, int next})? readWord(Uint8List buf, int off) {
  if (off >= buf.length) return null;
  final c = buf[off];
  int len, n;
  if (c & 0x80 == 0) {
    len = c;
    n = 1;
  } else if (c & 0xC0 == 0x80) {
    if (off + 2 > buf.length) return null;
    len = ((c & 0x3F) << 8) | buf[off + 1];
    n = 2;
  } else if (c & 0xE0 == 0xC0) {
    if (off + 3 > buf.length) return null;
    len = ((c & 0x1F) << 16) | (buf[off + 1] << 8) | buf[off + 2];
    n = 3;
  } else if (c & 0xF0 == 0xE0) {
    if (off + 4 > buf.length) return null;
    len = ((c & 0x0F) << 24) | (buf[off + 1] << 16) | (buf[off + 2] << 8) | buf[off + 3];
    n = 4;
  } else {
    if (off + 5 > buf.length) return null;
    len = (buf[off + 1] << 24) | (buf[off + 2] << 16) | (buf[off + 3] << 8) | buf[off + 4];
    n = 5;
  }
  if (off + n + len > buf.length) return null;
  return (word: utf8.decode(buf.sublist(off + n, off + n + len), allowMalformed: true), next: off + n + len);
}

Map<String, String> attrsOf(List<String> words) {
  final o = <String, String>{};
  for (final w in words) {
    if (w.isEmpty || w[0] != '=') continue;
    final i = w.indexOf('=', 1);
    if (i > 0) o[w.substring(1, i)] = w.substring(i + 1);
  }
  return o;
}

RouterError friendly(Object e, String host, int port) {
  final msg = e is RouterError ? e.message : (e is SocketException ? '${e.message} ${e.osError?.message ?? ''}' : e.toString());
  if (RegExp(r'refused', caseSensitive: false).hasMatch(msg)) {
    return RouterError('Connection refused by $host:$port. Turn on the API service on the router (IP > Services > api) and check the port.');
  }
  if (RegExp(r'timed out|timeout', caseSensitive: false).hasMatch(msg)) {
    return RouterError('No reply from $host:$port. Check the address, that the router is on, and that this device is on the router’s network.');
  }
  if (RegExp(r'unreachable|no route', caseSensitive: false).hasMatch(msg)) {
    return RouterError('$host cannot be reached from this device. Connect to the router’s network and try again.');
  }
  if (RegExp(r'invalid user name or password|cannot log in', caseSensitive: false).hasMatch(msg)) {
    return RouterError('Login failed: wrong username or password, or this user is not allowed to use the API.', kind: 'auth');
  }
  if (RegExp(r'handshake|tls|ssl|certificate', caseSensitive: false).hasMatch(msg)) {
    return RouterError('The secure (API-SSL) connection failed. Use the plain API port 8728 on the shop network.');
  }
  return e is RouterError ? e : RouterError(msg.trim());
}

class _Cmd {
  _Cmd(this.words);
  final List<String> words;
  final Completer<RouterReply> done = Completer<RouterReply>();
  final List<Map<String, String>> rows = [];
  String? trap;
  Timer? timer;
}

class RouterOS {
  RouterOS({required this.host, this.port = 8728, this.tls = false, required this.user, required this.password, this.timeout = const Duration(seconds: 8)});

  final String host;
  final int port;
  final bool tls;
  final String user;
  final String password;
  final Duration timeout;

  Socket? _sock;
  Uint8List _buf = Uint8List(0);
  final List<String> _words = [];
  final Queue<_Cmd> _queue = Queue<_Cmd>();
  _Cmd? _cur;
  bool closed = false;

  Future<RouterOS> connect() async {
    try {
      _sock = tls
          ? await SecureSocket.connect(host, port, timeout: timeout, onBadCertificate: (_) => true)
          : await Socket.connect(host, port, timeout: timeout);
    } catch (e) {
      closed = true;
      throw friendly(e, host, port);
    }
    _sock!.listen(_data, onError: (Object e) => _failAll(friendly(e, host, port)), onDone: () {
      closed = true;
      _failAll(RouterError('The router closed the connection.'));
    }, cancelOnError: true);
    try {
      final r = await run(['/login', '=name=$user', '=password=$password']);
      final ret = r.done['ret'];
      if (ret != null && ret.isNotEmpty) {
        // RouterOS older than 6.43: challenge and response
        final chal = <int>[];
        for (var i = 0; i + 1 < ret.length; i += 2) {
          chal.add(int.parse(ret.substring(i, i + 2), radix: 16));
        }
        final digest = md5.convert([0, ...utf8.encode(password), ...chal]).toString();
        await run(['/login', '=name=$user', '=response=00$digest']);
      }
    } catch (e) {
      close();
      throw friendly(e, host, port);
    }
    return this;
  }

  void _data(Uint8List d) {
    final b = BytesBuilder(copy: false)
      ..add(_buf)
      ..add(d);
    _buf = b.toBytes();
    var off = 0;
    while (true) {
      final r = readWord(_buf, off);
      if (r == null) break;
      off = r.next;
      if (r.word.isEmpty) {
        final w = List<String>.from(_words);
        _words.clear();
        _sentence(w);
      } else {
        _words.add(r.word);
      }
    }
    if (off > 0) _buf = Uint8List.fromList(_buf.sublist(off));
  }

  void _sentence(List<String> w) {
    final cur = _cur;
    if (cur == null || w.isEmpty) return;
    final type = w[0];
    final a = attrsOf(w.sublist(1));
    if (type == '!re') {
      cur.rows.add(a);
    } else if (type == '!trap') {
      cur.trap = a['message'] ?? 'The router reported an error.';
    } else if (type == '!fatal') {
      _failAll(RouterError(w.length > 1 ? w[1] : 'The router closed the connection.'));
    } else if (type == '!done') {
      cur.timer?.cancel();
      _cur = null;
      if (cur.trap != null) {
        cur.done.completeError(RouterError(cur.trap!));
      } else {
        cur.done.complete(RouterReply(cur.rows, a));
      }
      _next();
    }
  }

  void _failAll(RouterError e) {
    final all = <_Cmd>[if (_cur != null) _cur!, ..._queue];
    _cur = null;
    _queue.clear();
    for (final c in all) {
      c.timer?.cancel();
      if (!c.done.isCompleted) c.done.completeError(e);
    }
  }

  void _next() {
    if (_cur != null || _queue.isEmpty || _sock == null) return;
    final c = _cur = _queue.removeFirst();
    c.timer = Timer(timeout, () {
      _failAll(RouterError('The router did not answer in time.'));
      close();
    });
    _sock!.add(encodeSentence(c.words));
  }

  Future<RouterReply> run(List<String> words) {
    if (closed) return Future.error(RouterError('Not connected.'));
    final c = _Cmd(words);
    _queue.add(c);
    _next();
    return c.done.future;
  }

  void close() {
    closed = true;
    try {
      _sock?.destroy();
    } catch (_) {}
  }
}
