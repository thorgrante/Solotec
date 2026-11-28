// What the website can ask of the app (window.HVNative.call(op, args) in the page).
//   info                      platform, version, device name
//   connector {branch}        this install's link for that branch, if any: {id}
//   connector {branch,id,key} keep the key the website just made for this install (POST /api/connector/self)
//   forget {branch}           drop it
//   saveFile {name,mime,data} a file the page made (tickets PDF, CSV, ...), base64
//   alerts {on,server,key}    Android: pop-up alerts with the tune while the app is closed
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'connector.dart';

class Bridge {
  Bridge({required this.connector, required this.platform, required this.version, required this.device, required this.install});
  final Connector connector;
  final String platform, version, device, install;

  /// The script every page gets before its own code runs.
  String script() {
    final cfg = jsonEncode({'platform': platform, 'version': version, 'device': device, 'install': install});
    return '''
(function(){if(window.HVNative)return;var cfg=$cfg;
function call(op,a){return new Promise(function(ok,no){
 function go(){window.flutter_inappwebview.callHandler('hv',Object.assign({op:op},a||{})).then(function(r){
  if(r&&r.error){var e=new Error(r.error);if(r.code)e.code=r.code;no(e)}else ok(r||{})},no)}
 if(window.flutter_inappwebview&&window.flutter_inappwebview.callHandler)go();
 else window.addEventListener('flutterInAppWebViewPlatformReady',go,{once:true})})}
window.HVNative={platform:cfg.platform,version:cfg.version,device:cfg.device,install:cfg.install,call:call};
document.documentElement.setAttribute('data-app',cfg.platform);
// Files the page builds and "downloads" (<a download href="blob:..."> or data:) are handed to the app.
var keep=URL.revokeObjectURL.bind(URL);URL.revokeObjectURL=function(u){setTimeout(function(){keep(u)},60000)};
function save(a){var name=a.getAttribute('download')||'download';
 fetch(a.href).then(function(r){return r.blob()}).then(function(b){return new Promise(function(ok,no){var fr=new FileReader();
  fr.onload=function(){ok({mime:b.type||'application/octet-stream',data:String(fr.result).split(',')[1]||''})};fr.onerror=no;fr.readAsDataURL(b)})})
 .then(function(f){return call('saveFile',{name:name,mime:f.mime,data:f.data})}).catch(function(e){console.error('Could not save '+name+': '+(e&&e.message||e))})}
var isFile=function(a){return a&&a.hasAttribute&&a.hasAttribute('download')&&/^(blob|data):/i.test(a.href||'')};
var click=HTMLAnchorElement.prototype.click;
HTMLAnchorElement.prototype.click=function(){if(isFile(this)){save(this);return}return click.apply(this,arguments)};
document.addEventListener('click',function(e){var a=e.target&&e.target.closest?e.target.closest('a'):null;if(isFile(a)){e.preventDefault();e.stopPropagation();save(a)}},true);
})();
''';
  }

  Future<Map<String, dynamic>> handle(List<dynamic> args, String server) async {
    try {
      final a = args.isNotEmpty && args[0] is Map ? Map<String, dynamic>.from(args[0] as Map) : <String, dynamic>{};
      final op = a['op'];
      int branchOf() => a['branch'] is int ? a['branch'] as int : int.tryParse('${a['branch']}') ?? 1;
      switch (op) {
        case 'info':
          return {'platform': platform, 'version': version, 'device': device};
        case 'connector':
          final b = branchOf();
          if (a['key'] is String && a['id'] != null) {
            final id = a['id'] is int ? a['id'] as int : int.parse('${a['id']}');
            final l = await connector.attach(server, b, id, a['key'] as String);
            return {'id': l.id};
          }
          final l = connector.find(server, b);
          return l == null ? {} : {'id': l.id};
        case 'forget':
          await connector.forget(server, branchOf());
          return {'ok': true};
        case 'alerts': // ticket alerts with the app closed (Android): {on, server, key}
          if (!Platform.isAndroid) return {'ok': false};
          await const MethodChannel('hv/native').invokeMethod('alerts', {'on': a['on'] == true, 'server': '${a['server'] ?? server}', 'key': '${a['key'] ?? ''}'});
          return {'ok': true};
        case 'alertsStatus': // is the watcher on, last time it reached the server, may it show pop-ups (Android)
          if (!Platform.isAndroid) return {'on': false};
          final st = await const MethodChannel('hv/native').invokeMethod('alertsStatus');
          return Map<String, dynamic>.from(st as Map);
        case 'alertsSettings': // the phone's notification settings for Solotik (Android)
          if (Platform.isAndroid) await const MethodChannel('hv/native').invokeMethod('alertsSettings');
          return {'ok': true};
        case 'saveFile':
          return await _saveFile('${a['name'] ?? 'download'}', '${a['mime'] ?? 'application/octet-stream'}', '${a['data'] ?? ''}');
      }
      return {'error': 'Unknown request.'};
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> _saveFile(String name, String mime, String data) async {
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|\u0000-\u001f]'), '_');
    final bytes = base64Decode(data);
    if (Platform.isWindows) {
      final loc = await getSaveLocation(suggestedName: safe);
      if (loc == null) return {'saved': false};
      await File(loc.path).writeAsBytes(bytes, flush: true);
      return {'saved': true};
    }
    // Android: the share sheet lets the owner save it to Files or Drive, print it, or send it.
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}${Platform.pathSeparator}$safe');
    await f.writeAsBytes(bytes, flush: true);
    // Kept in Downloads/Solotik and opened in the phone's own viewer, in its own window; the share sheet when that is not possible.
    try {
      final opened = await const MethodChannel('hv/native').invokeMethod<bool>('saveOpen', {'path': f.path, 'name': safe, 'mime': mime});
      if (opened == true) return {'saved': true, 'where': 'Downloads/Solotik'};
    } catch (_) {}
    await Share.shareXFiles([XFile(f.path, mimeType: mime, name: safe)]);
    return {'saved': true};
  }
}
