// The website, full screen, with the app's extras (router finding, saving files). Links to other sites open in the
// browser. When the website cannot be reached, a plain screen says so, with Try again and the server address.
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'bridge.dart';
import 'config.dart';

class WebShell extends StatefulWidget {
  const WebShell({super.key, required this.bridge, required this.server});
  final Bridge bridge;
  final String server;
  @override
  State<WebShell> createState() => _WebShellState();
}

class _WebShellState extends State<WebShell> {
  InAppWebViewController? _c;
  late String _server = _origin(widget.server);
  bool _failed = false;
  double _progress = 0;

  static String _origin(String s) {
    var u = s.trim();
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(u)) u = 'https://$u';
    final p = Uri.tryParse(u);
    if (p == null || p.host.isEmpty) return defaultServer;
    return p.hasPort && p.port != 443 && p.port != 80 ? '${p.scheme}://${p.host}:${p.port}' : '${p.scheme}://${p.host}';
  }

  bool _ours(Uri? u) {
    if (u == null) return false;
    final s = Uri.parse(_server);
    return u.host == s.host;
  }

  Future<void> _external(Uri u) async {
    try {
      await launchUrl(u, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  void _retry() {
    setState(() => _failed = false);
    _c?.loadUrl(urlRequest: URLRequest(url: WebUri('$_server/')));
  }

  Future<void> _changeServer() async {
    final t = TextEditingController(text: _server);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Server address'),
        content: TextField(controller: t, keyboardType: TextInputType.url, autofocus: true, decoration: const InputDecoration(hintText: defaultServer)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, defaultServer), child: const Text('Use default')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, t.text), child: const Text('Save')),
        ],
      ),
    );
    if (v == null || v.trim().isEmpty) return;
    final o = _origin(v);
    final p = await SharedPreferences.getInstance();
    await p.setString('hv.server', o);
    setState(() => _server = o);
    _retry();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final c = _c;
        if (c != null && await c.canGoBack()) {
          await c.goBack();
        } else {
          await SystemNavigator.pop();
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: Stack(children: [
            InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri('$_server/')),
              initialUserScripts: UnmodifiableListView<UserScript>([
                UserScript(source: widget.bridge.script(), injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START),
              ]),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                javaScriptCanOpenWindowsAutomatically: true,
                supportMultipleWindows: true,
                useShouldOverrideUrlLoading: true,
                useOnDownloadStart: true,
                mediaPlaybackRequiresUserGesture: true,
                supportZoom: false,
                applicationNameForUserAgent: '$appName/$appVersion',
              ),
              onWebViewCreated: (c) {
                _c = c;
                c.addJavaScriptHandler(handlerName: 'hv', callback: (args) => widget.bridge.handle(args, _server));
              },
              shouldOverrideUrlLoading: (c, action) async {
                final u = action.request.url;
                if (u == null) return NavigationActionPolicy.ALLOW;
                final scheme = u.scheme.toLowerCase();
                if (scheme == 'about' || scheme == 'data' || scheme == 'blob' || scheme == 'javascript') return NavigationActionPolicy.ALLOW;
                if ((scheme == 'http' || scheme == 'https') && _ours(u)) return NavigationActionPolicy.ALLOW;
                if (action.isForMainFrame == false && (scheme == 'http' || scheme == 'https')) return NavigationActionPolicy.ALLOW;
                await _external(u);
                return NavigationActionPolicy.CANCEL;
              },
              onCreateWindow: (c, action) async {
                final u = action.request.url;
                if (u != null) {
                  if (_ours(u)) {
                    await c.loadUrl(urlRequest: URLRequest(url: u));
                  } else {
                    await _external(u);
                  }
                }
                return false;
              },
              onDownloadStartRequest: (c, req) async {
                final u = req.url;
                if (u.scheme == 'http' || u.scheme == 'https') await _external(u);
              },
              onProgressChanged: (c, p) => setState(() => _progress = p / 100),
              onReceivedError: (c, req, err) {
                if (req.isForMainFrame ?? true) setState(() => _failed = true);
              },
            ),
            if (_progress < 1 && !_failed) LinearProgressIndicator(value: _progress == 0 ? null : _progress, minHeight: 3),
            if (_failed) _Offline(onRetry: _retry, onServer: _changeServer, server: _server),
          ]),
        ),
      ),
    );
  }
}

class _Offline extends StatelessWidget {
  const _Offline({required this.onRetry, required this.onServer, required this.server});
  final VoidCallback onRetry, onServer;
  final String server;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Positioned.fill(
      child: ColoredBox(
        color: t.colorScheme.surface,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.wifi_off_rounded, size: 56, color: t.colorScheme.primary),
                const SizedBox(height: 16),
                Text('Can’t reach the server', style: t.textTheme.titleLarge, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text('Check your internet connection, then try again.', style: t.textTheme.bodyMedium, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                FilledButton(onPressed: onRetry, child: const Text('Try again')),
                const SizedBox(height: 8),
                TextButton(onPressed: onServer, child: Text('Server: ${Uri.parse(server).host}')),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
