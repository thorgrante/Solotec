// The website, full screen, with the app's extras (router finding, saving files). Links to other sites open in the
// browser. Without internet a plain screen says so; Try again checks first and, while there is still no internet, only
// shows "No internet connection" at the top. The phone's own "Web page not available" page is never shown.
import 'dart:async';
import 'dart:collection';
import 'dart:io';

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

class _WebShellState extends State<WebShell> with WidgetsBindingObserver {
  Color? _top, _bottom; // the page's colours at the very top and bottom of the screen

  static Color? _css(Object? v) {
    final m = RegExp(r'rgba?\((\d+),\s*(\d+),\s*(\d+)').firstMatch('$v');
    if (m == null) return null;
    return Color.fromARGB(255, int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  }

  // Tells the app which colours the page shows at the top and the bottom edge (solid colours only).
  static const _barsScript = r'''
(function(){if(window.__hvBars)return;window.__hvBars=1;var last='';
function solid(c){var m=/rgba\(([^)]+)\)/.exec(c);return c&&c!=='transparent'&&(!m||parseFloat(m[1].split(',')[3])>=1)}
function col(el){while(el&&el.nodeType===1){var c=getComputedStyle(el).backgroundColor;if(solid(c))return c;el=el.parentElement}
 var b=getComputedStyle(document.body).backgroundColor;return solid(b)?b:getComputedStyle(document.documentElement).backgroundColor}
function send(){try{var w=innerWidth,h=innerHeight,t=col(document.elementFromPoint(w/2,1)),b=col(document.elementFromPoint(w/2,h-2)),k=t+'|'+b;
 if(k!==last&&window.flutter_inappwebview&&window.flutter_inappwebview.callHandler){last=k;window.flutter_inappwebview.callHandler('bars',t,b)}}catch(e){}}
setInterval(send,300);addEventListener('scroll',send,{passive:true});send()})();
''';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Back from another app: Android may have paused the page's timers and network while it was in the background.
  // Wake the page up and let it check the connection again at once (instead of waiting for its next timer).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _c;
    if (c == null || state != AppLifecycleState.resumed) return;
    () async {
      try {
        if (Platform.isAndroid) {
          await c.resume();
          await c.resumeTimers();
        }
        await c.evaluateJavascript(source: "window.dispatchEvent(new Event('online'))");
      } catch (_) {}
    }();
  }

  InAppWebViewController? _c;
  late String _server = _origin(widget.server);
  bool _failed = false;
  double _progress = 0;
  bool _shown = false; // the first page has appeared

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

  bool _checking = false;
  String? _toast;
  Timer? _toastT, _auto;

  /// Can this device reach the website right now?
  Future<bool> _reachable() async {
    final h = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final r = await (await h.getUrl(Uri.parse('$_server/api/health'))).close().timeout(const Duration(seconds: 8));
      await r.drain<void>();
      return r.statusCode < 500;
    } catch (_) {
      return false;
    } finally {
      h.close(force: true);
    }
  }

  void _say(String t) {
    _toastT?.cancel();
    setState(() => _toast = t);
    _toastT = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  void _offline() {
    if (!_failed) setState(() => _failed = true);
    // check quietly every few seconds, and carry on by itself when the internet is back
    _auto ??= Timer.periodic(const Duration(seconds: 6), (_) async {
      if (!_failed || _checking) return;
      if (await _reachable()) _retry(quiet: true);
    });
  }

  Future<void> _retry({bool quiet = false}) async {
    if (_checking) return;
    setState(() => _checking = true);
    final ok = await _reachable();
    if (!mounted) return;
    setState(() => _checking = false);
    if (!ok) {
      if (!quiet) _say('No internet connection');
      return;
    }
    _auto?.cancel();
    _auto = null;
    setState(() {
      _failed = false;
      _progress = 0;
    });
    await _c?.loadUrl(urlRequest: URLRequest(url: WebUri('$_server/')));
  }

  @override
  void deactivate() {
    _toastT?.cancel();
    _auto?.cancel();
    super.deactivate();
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
      child: Builder(builder: (context) {
        // Full screen: the page reaches the phone's status bar and bottom bar, and both take the colour of the page
        // under them (purple behind the header, the page colour at the bottom), so no empty bars show.
        final surface = Theme.of(context).colorScheme.surface;
        final cover = _failed || !_shown;
        final top = cover ? surface : (_top ?? surface), bottom = cover ? surface : (_bottom ?? surface);
        Brightness icons(Color c) => c.computeLuminance() > .5 ? Brightness.dark : Brightness.light;
        final pad = MediaQuery.paddingOf(context);
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: icons(top),
            statusBarBrightness: icons(top) == Brightness.dark ? Brightness.light : Brightness.dark,
            systemNavigationBarColor: bottom,
            systemNavigationBarDividerColor: bottom,
            systemNavigationBarIconBrightness: icons(bottom),
            systemNavigationBarContrastEnforced: false,
          ),
          child: Scaffold(
        backgroundColor: bottom,
        body: Column(children: [
          Container(height: pad.top, color: top),
          Expanded(child: SafeArea(
          top: false,
          child: Stack(children: [
            InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri('$_server/')),
              initialUserScripts: UnmodifiableListView<UserScript>([
                UserScript(source: widget.bridge.script(), injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START),
                UserScript(source: _barsScript, injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END),
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
                c.addJavaScriptHandler(handlerName: 'bars', callback: (args) {
                  final t = args.isNotEmpty ? _css(args[0]) : null, b = args.length > 1 ? _css(args[1]) : null;
                  if (mounted && (t != _top || b != _bottom)) setState(() {
                    _top = t;
                    _bottom = b;
                  });
                  return null;
                });
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
              onProgressChanged: (c, p) => setState(() {
                _progress = p / 100;
                if (p >= 100) _shown = true;
              }),
              onReceivedError: (c, req, err) {
                if (req.isForMainFrame == true) _offline();
              },
              onLoadStop: (c, url) async {
                // the phone's own error page ("Web page not available") is never left on screen
                final u = url?.toString() ?? '';
                if (u.startsWith('chrome-error:') || u.startsWith('about:neterror') || (u == 'about:blank' && _failed)) _offline();
              },
            ),
            // loading: a turning circular arrow. Over a plain screen while the app opens, over the page after that.
            if (_progress < 1 && !_failed) Positioned.fill(child: _Loading(cover: !_shown)),
            if (_failed) _Offline(onRetry: () => _retry(), onServer: _changeServer, checking: _checking),
            // "No internet connection" at the top, the way other apps say it
            Positioned(
              top: 12,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: AnimatedSlide(
                  offset: _toast == null ? const Offset(0, -2) : Offset.zero,
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOut,
                  child: AnimatedOpacity(
                    opacity: _toast == null ? 0 : 1,
                    duration: const Duration(milliseconds: 200),
                    child: Center(
                      child: DecoratedBox(
                        decoration: BoxDecoration(color: const Color(0xFFE5484D), borderRadius: BorderRadius.circular(999), boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 14, offset: Offset(0, 4))]),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                          child: Text(_toast ?? '', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ]),
        )),
        ]),
          ),
        );
      }),
    );
  }
}

class _Offline extends StatelessWidget {
  const _Offline({required this.onRetry, required this.onServer, required this.checking});
  final VoidCallback onRetry, onServer;
  final bool checking;
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
                // a long press on the icon opens the server address (for support only; not shown to customers)
                GestureDetector(onLongPress: onServer, child: Icon(Icons.wifi_off_rounded, size: 56, color: t.colorScheme.primary)),
                const SizedBox(height: 16),
                Text('Can’t access the internet', style: t.textTheme.titleLarge, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text('Check your internet connection.', style: t.textTheme.bodyMedium, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: checking ? null : onRetry,
                  child: checking
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4))
                      : const Text('Try again'),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _Loading extends StatefulWidget {
  const _Loading({required this.cover});
  final bool cover;
  @override
  State<_Loading> createState() => _LoadingState();
}

/// The Solotik logo inside a turning gradient ring. Full screen while the app opens; a floating badge over the page
/// while a page reloads (after signing in, for example).
class _LoadingState extends State<_Loading> with TickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 850))..repeat();
  late final AnimationController _breathe = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))..repeat(reverse: true);

  @override
  void dispose() {
    _spin.dispose();
    _breathe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final size = widget.cover ? 104.0 : 76.0, logo = widget.cover ? 68.0 : 48.0;
    final mark = SizedBox(
      width: size,
      height: size,
      child: Stack(alignment: Alignment.center, children: [
        RotationTransition(turns: _spin, child: CustomPaint(size: Size.square(size), painter: _Ring(widget.cover ? 7 : 5))),
        ScaleTransition(
          scale: Tween(begin: .92, end: 1.0).animate(CurvedAnimation(parent: _breathe, curve: Curves.easeInOut)),
          child: Container(
            width: logo,
            height: logo,
            decoration: const BoxDecoration(shape: BoxShape.circle, boxShadow: [BoxShadow(color: Color(0x474A00A0), blurRadius: 22, offset: Offset(0, 8))]),
            child: ClipOval(child: Image.asset('assets/icon.png', fit: BoxFit.cover, semanticLabel: 'Loading')),
          ),
        ),
      ]),
    );
    return IgnorePointer(
      ignoring: !widget.cover,
      child: ColoredBox(
        color: widget.cover ? t.colorScheme.surface : Colors.transparent,
        child: Center(
          child: widget.cover
              ? mark
              : DecoratedBox(
                  decoration: BoxDecoration(color: t.colorScheme.surface.withValues(alpha: .96), shape: BoxShape.circle, boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 24, offset: Offset(0, 8))]),
                  child: Padding(padding: const EdgeInsets.all(10), child: mark),
                ),
        ),
      ),
    );
  }
}

class _Ring extends CustomPainter {
  _Ring(this.width);
  final double width;
  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..shader = const SweepGradient(colors: [Color(0x007F19FF), Color(0x337F19FF), Color(0xFFB07BFF), Color(0xFF7F19FF)], stops: [0, .25, .62, .92]).createShader(r);
    canvas.drawArc(r.deflate(width / 2), 0.15, 6.0, false, p);
  }

  @override
  bool shouldRepaint(_Ring old) => old.width != width;
}
