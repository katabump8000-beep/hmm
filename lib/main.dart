import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

const Color kBlack = Color(0xFF0A0509);
const Color kWine = Color(0xFF7A1038);
const Color kDeepWine = Color(0xFF3B0A1E);
const Color kPink = Color(0xFFFF5FA2);
const Color kSoftPink = Color(0xFFFFB3D1);
const String kVersion = '2.0.0';

final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
final GlobalKey<ScaffoldMessengerState> msgKey = GlobalKey<ScaffoldMessengerState>();
final AppState app = AppState();

// ───────────────────────── أدوات مساعدة ─────────────────────────

void toast(String m) {
  msgKey.currentState?.hideCurrentSnackBar();
  msgKey.currentState?.showSnackBar(SnackBar(
    content: Text(m),
    behavior: SnackBarBehavior.floating,
    backgroundColor: kDeepWine,
    duration: const Duration(seconds: 3),
  ));
}

String fmtBytes(num b) {
  const List<String> u = ['B', 'KB', 'MB', 'GB'];
  double v = b.toDouble();
  int i = 0;
  while (v >= 1024 && i < 3) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i < 2 ? 0 : 1)} ${u[i]}';
}

String fmtDur(int s) {
  final int h = s ~/ 3600;
  final int m = (s % 3600) ~/ 60;
  final int sec = s % 60;
  String two(int x) => x.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '${two(m)}:${two(sec)}';
}

String fmtDate(int ms) {
  final DateTime d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.year}/${d.month}/${d.day}';
}

String friendly(String raw) {
  final String r = raw.toLowerCase();
  if (r.contains('unsupported url')) return 'هذا الرابط أو الموقع غير مدعوم.';
  if (r.contains('sign in') || r.contains('log in') || r.contains('login') || r.contains('cookies') || r.contains('private')) {
    return 'المحتوى خاص أو يتطلب تسجيل دخول، ولا يمكن تنزيله.';
  }
  if (r.contains('429') || r.contains('too many requests')) return 'الموقع حدّ الطلبات مؤقتاً. حاول لاحقاً.';
  if (r.contains('unavailable') || r.contains('removed') || r.contains('404')) return 'المحتوى غير متاح أو محذوف.';
  if (r.contains('unable to resolve') || r.contains('urlopen') || r.contains('timed out') || r.contains('network') || r.contains('socketexception') || r.contains('connection')) {
    return 'تعذر الاتصال بالموقع. تحقق من الإنترنت.';
  }
  if (r.contains('no space') || r.contains('enospc')) return 'لا توجد مساحة كافية على الجهاز.';
  final String line = raw.trim().split('\n').last.trim();
  return line.length > 220 ? line.substring(0, 220) : line;
}

String? extractUrl(String raw) {
  final RegExpMatch? m = RegExp(r'https?://[^\s]+').firstMatch(raw);
  if (m != null) return m.group(0)!.replaceAll(RegExp(r'[)\]>,.]+$'), '');
  final String t = raw.trim();
  if (t.contains('.') && !t.contains(' ') && t.length > 3) return 'https://$t';
  return null;
}

Route<T> fade<T>(Widget w) => PageRouteBuilder<T>(
      transitionDuration: const Duration(milliseconds: 380),
      reverseTransitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (BuildContext c, Animation<double> a, Animation<double> b) => w,
      transitionsBuilder: (BuildContext c, Animation<double> a, Animation<double> b, Widget child) {
        final CurvedAnimation cur = CurvedAnimation(parent: a, curve: Curves.easeOutCubic);
        return FadeTransition(
          opacity: cur,
          child: SlideTransition(
            position: Tween<Offset>(begin: const Offset(0, 0.04), end: Offset.zero).animate(cur),
            child: child,
          ),
        );
      },
    );

// ───────────────────────── الجسر مع Android ─────────────────────────

class Native {
  static const MethodChannel ch = MethodChannel('jesi/native');

  static Future<String?> takeShare() async {
    try {
      return await ch.invokeMethod<String>('takeShare');
    } catch (_) {
      return null;
    }
  }

  static Future<String> analyze(String url) async {
    final String? r = await ch.invokeMethod<String>('analyze', <String, dynamic>{'url': url});
    return r ?? '';
  }

  static Future<Map<String, dynamic>> download(Map<String, dynamic> a) async {
    final Map<Object?, Object?>? r = await ch.invokeMethod<Map<Object?, Object?>>('download', a);
    return r == null ? <String, dynamic>{} : Map<String, dynamic>.from(r);
  }

  static Future<Map<String, dynamic>> publish(String path) async {
    final Map<Object?, Object?>? r =
        await ch.invokeMethod<Map<Object?, Object?>>('publish', <String, dynamic>{'path': path});
    return r == null ? <String, dynamic>{} : Map<String, dynamic>.from(r);
  }

  static Future<void> pause(String id) async {
    try {
      await ch.invokeMethod<bool>('pause', <String, dynamic>{'id': id});
    } catch (_) {}
  }

  static Future<void> cancel(String id) async {
    try {
      await ch.invokeMethod<bool>('cancel', <String, dynamic>{'id': id});
    } catch (_) {}
  }

  static Future<bool> exists(String uri) async {
    try {
      return (await ch.invokeMethod<bool>('exists', <String, dynamic>{'uri': uri})) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> delete(String uri) async {
    try {
      return (await ch.invokeMethod<bool>('delete', <String, dynamic>{'uri': uri})) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> open(String uri, String mime) async {
    try {
      await ch.invokeMethod<bool>('open', <String, dynamic>{'uri': uri, 'mime': mime});
    } on PlatformException catch (e) {
      toast(e.message ?? 'تعذر فتح الملف');
    }
  }

  static Future<void> share(String uri, String mime) async {
    try {
      await ch.invokeMethod<bool>('share', <String, dynamic>{'uri': uri, 'mime': mime});
    } on PlatformException catch (e) {
      toast(e.message ?? 'تعذرت المشاركة');
    }
  }

  static Future<String> updateEngine() async {
    final String? r = await ch.invokeMethod<String>('updateEngine');
    return r ?? 'OK';
  }
}

// ───────────────────────── النماذج ─────────────────────────

enum St { queued, running, paused, waiting, processing, done, failed }

class Opt {
  final String label;
  final String sel;
  final String? audio;
  final int? bytes;
  final bool isAudio;
  final bool direct;
  const Opt(this.label, this.sel, {this.audio, this.bytes, this.isAudio = false, this.direct = false});
}

class Info {
  final String title;
  final String thumb;
  final String site;
  final String uploader;
  final int dur;
  final List<Opt> opts;
  const Info(this.title, this.thumb, this.site, this.uploader, this.dur, this.opts);
}

class Task {
  final String id;
  final String url;
  String title;
  String thumb;
  String format;
  String? audio;
  String mode;
  bool direct;
  St st;
  double pct;
  String speed;
  String eta;
  String size;
  String err;
  String note;
  bool fell;
  Map<String, dynamic>? res;

  Task({
    required this.id,
    required this.url,
    required this.title,
    required this.thumb,
    required this.format,
    required this.mode,
    this.audio,
    this.direct = false,
    this.st = St.queued,
    this.pct = 0,
    this.speed = '—',
    this.eta = '—',
    this.size = '—',
    this.err = '',
    this.note = '',
    this.fell = false,
    this.res,
  });

  bool get active => st == St.running || st == St.processing || st == St.queued;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'url': url,
        'title': title,
        'thumb': thumb,
        'format': format,
        'audio': audio,
        'mode': mode,
        'direct': direct,
        'st': st.index,
        'pct': pct,
        'size': size,
        'err': err,
        'note': note,
        'fell': fell,
        'res': res,
      };

  factory Task.fromJson(Map<String, dynamic> j) {
    final Task t = Task(
      id: j['id'] as String,
      url: j['url'] as String,
      title: (j['title'] ?? '') as String,
      thumb: (j['thumb'] ?? '') as String,
      format: (j['format'] ?? 'b') as String,
      mode: (j['mode'] ?? 'classic') as String,
      audio: j['audio'] as String?,
      direct: (j['direct'] ?? false) as bool,
      st: St.values[(j['st'] ?? 0) as int],
      pct: ((j['pct'] ?? 0) as num).toDouble(),
      size: (j['size'] ?? '—') as String,
      err: (j['err'] ?? '') as String,
      note: (j['note'] ?? '') as String,
      fell: (j['fell'] ?? false) as bool,
    );
    final Object? r = j['res'];
    if (r is Map) t.res = Map<String, dynamic>.from(r);
    return t;
  }
}

// ───────────────────────── حالة التطبيق ─────────────────────────

class AppState extends ChangeNotifier {
  SharedPreferences? prefs;
  final List<Task> tasks = <Task>[];
  final List<Map<String, dynamic>> library = <Map<String, dynamic>>[];
  final ValueNotifier<int> tab = ValueNotifier<int>(0);
  final TextEditingController urlCtl = TextEditingController();
  final Set<String> _active = <String>{};
  final Map<String, String> _stop = <String, String>{};
  final Map<String, HttpClient> _clients = <String, HttpClient>{};
  String mode = 'classic';
  bool autoUpdate = true;
  bool online = true;
  StreamSubscription<List<ConnectivityResult>>? _sub;

  Future<void> init() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    prefs = p;
    mode = p.getString('mode') ?? 'classic';
    autoUpdate = p.getBool('autoUpdate') ?? true;
    try {
      final Object? t = jsonDecode(p.getString('tasks') ?? '[]');
      if (t is List) {
        for (final Object? e in t) {
          if (e is Map) {
            final Task k = Task.fromJson(Map<String, dynamic>.from(e));
            if (k.st == St.running || k.st == St.processing || k.st == St.queued || k.st == St.waiting) {
              k.st = St.paused;
            }
            tasks.add(k);
          }
        }
      }
      final Object? l = jsonDecode(p.getString('library') ?? '[]');
      if (l is List) {
        for (final Object? e in l) {
          if (e is Map) library.add(Map<String, dynamic>.from(e));
        }
      }
    } catch (_) {}
    Native.ch.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'progress') {
        final Map<Object?, Object?> a = call.arguments as Map<Object?, Object?>;
        _onProgress(
          a['id'] as String,
          ((a['p'] ?? -1) as num).toDouble(),
          ((a['eta'] ?? -1) as num).toInt(),
          (a['line'] ?? '') as String,
        );
      } else if (call.method == 'shareReady') {
        checkShare();
      }
      return null;
    });
    try {
      final List<ConnectivityResult> r = await Connectivity().checkConnectivity();
      online = !r.contains(ConnectivityResult.none);
      _sub = Connectivity().onConnectivityChanged.listen(_onNet);
    } catch (_) {}
    if (autoUpdate) _autoUpdate();
  }

  Future<void> _autoUpdate() async {
    final SharedPreferences? p = prefs;
    if (p == null || !online) return;
    final int last = p.getInt('lastUpd') ?? 0;
    final int now = DateTime.now().millisecondsSinceEpoch;
    if (now - last < 24 * 3600 * 1000) return;
    try {
      await Native.updateEngine();
      await p.setInt('lastUpd', now);
    } catch (_) {}
  }

  void setMode(String m) {
    mode = m;
    prefs?.setString('mode', m);
    notifyListeners();
  }

  void setAutoUpdate(bool v) {
    autoUpdate = v;
    prefs?.setBool('autoUpdate', v);
    notifyListeners();
  }

  void _save() {
    final SharedPreferences? p = prefs;
    if (p == null) return;
    final List<Task> keep = tasks.length > 40 ? tasks.sublist(tasks.length - 40) : tasks;
    p.setString('tasks', jsonEncode(keep.map((Task t) => t.toJson()).toList()));
    p.setString('library', jsonEncode(library));
  }

  void _notify() {
    notifyListeners();
  }

  Task? _byId(String id) {
    for (final Task t in tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  bool hasActive(String url, String format) {
    for (final Task t in tasks) {
      if (t.url == url && t.format == format && t.st != St.done && t.st != St.failed) return true;
    }
    return false;
  }

  // استقبال المشاركة
  Future<void> checkShare() async {
    final String? s = await Native.takeShare();
    if (s == null || s.trim().isEmpty) return;
    final String? u = extractUrl(s);
    if (u == null) {
      toast('لم أجد رابطاً في المحتوى المشترك');
      return;
    }
    openPreview(u);
  }

  void openPreview(String url) {
    navKey.currentState?.push(fade<void>(PreviewPage(url: url)));
  }

  // تحليل الرابط
  Future<Info> analyze(String url) async {
    String probe = '';
    try {
      probe = await _probe(url);
    } catch (_) {}
    if (probe.startsWith('image/')) return _directInfo(url, probe);
    try {
      final String raw = await Native.analyze(url);
      return _parse(raw);
    } on PlatformException catch (e) {
      if (probe.startsWith('video/') || probe.startsWith('audio/')) return _directInfo(url, probe);
      throw friendly(e.message ?? e.toString());
    } catch (e) {
      throw friendly(e.toString());
    }
  }

  Future<String> _probe(String url) async {
    final HttpClient c = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final HttpClientRequest rq = await c.openUrl('HEAD', Uri.parse(url));
      rq.followRedirects = true;
      final HttpClientResponse rs = await rq.close().timeout(const Duration(seconds: 8));
      await rs.drain<void>();
      return (rs.headers.contentType?.mimeType ?? '').toLowerCase();
    } finally {
      c.close(force: true);
    }
  }

  Info _directInfo(String url, String mime) {
    final Uri u = Uri.parse(url);
    String name = u.pathSegments.isNotEmpty ? u.pathSegments.last : 'file';
    if (!name.contains('.')) {
      const Map<String, String> ext = <String, String>{
        'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp', 'image/gif': 'gif',
        'video/mp4': 'mp4', 'video/webm': 'webm', 'audio/mpeg': 'mp3', 'audio/mp4': 'm4a',
      };
      name = '$name.${ext[mime] ?? 'bin'}';
    }
    final bool img = mime.startsWith('image/');
    return Info(name, img ? url : '', u.host, '', 0,
        <Opt>[Opt('الملف الأصلي', 'direct', direct: true, isAudio: mime.startsWith('audio/'))]);
  }

  Info _parse(String raw) {
    final String line = raw.split('\n').lastWhere((String l) => l.trimLeft().startsWith('{'), orElse: () => '');
    if (line.isEmpty) throw 'لم يتمكن المحرك من قراءة معلومات هذا الرابط.';
    final Map<String, dynamic> j = Map<String, dynamic>.from(jsonDecode(line) as Map);
    final List<Map<String, dynamic>> fs = <Map<String, dynamic>>[];
    final Object? rawF = j['formats'];
    if (rawF is List) {
      for (final Object? f in rawF) {
        if (f is Map) fs.add(Map<String, dynamic>.from(f));
      }
    }
    int? size(Map<String, dynamic> f) {
      final Object? a = f['filesize'] ?? f['filesize_approx'];
      return a is num ? a.toInt() : null;
    }

    bool hasV(Map<String, dynamic> f) => f['vcodec'] != null && f['vcodec'] != 'none';
    bool hasA(Map<String, dynamic> f) => f['acodec'] != null && f['acodec'] != 'none';
    int bestAudio = 0;
    int? m4aSize;
    for (final Map<String, dynamic> f in fs) {
      if (hasA(f) && !hasV(f)) {
        final int s = size(f) ?? 0;
        if (s > bestAudio) bestAudio = s;
        if (f['ext'] == 'm4a' && s > (m4aSize ?? 0)) m4aSize = s;
      }
    }
    final Map<int, int?> heights = <int, int?>{};
    for (final Map<String, dynamic> f in fs) {
      final Object? h = f['height'];
      if (hasV(f) && h is num && h > 0) {
        final int hh = h.toInt();
        int? s = size(f);
        if (s != null && !hasA(f)) s += bestAudio;
        final int? old = heights[hh];
        if (!heights.containsKey(hh) || (s != null && (old == null || s > old))) heights[hh] = s;
      }
    }
    final List<Opt> opts = <Opt>[];
    final List<int> hs = heights.keys.toList()..sort();
    for (final int h in hs) {
      String tag = '${h}p';
      if (h == 720) tag = '720p HD';
      if (h == 1080) tag = '1080p Full HD';
      if (h == 1440) tag = '1440p 2K';
      if (h == 2160) tag = '2160p 4K';
      opts.add(Opt(tag,
          'bv*[height=$h][vcodec^=avc1]+ba[ext=m4a]/bv*[height=$h]+ba/b[height=$h]/b',
          bytes: heights[h]));
    }
    if (hs.isEmpty && fs.isNotEmpty && fs.any(hasV)) {
      opts.add(const Opt('أفضل جودة متاحة', 'bv*+ba/b'));
    }
    if (fs.isEmpty) {
      opts.add(const Opt('أفضل جودة متاحة', 'b'));
    }
    if (fs.isEmpty || fs.any(hasA)) {
      opts.add(const Opt('MP3 صوت', 'ba/b', audio: 'mp3', isAudio: true));
      opts.add(Opt('M4A صوت', 'ba[ext=m4a]/ba/b', audio: 'm4a', isAudio: true, bytes: m4aSize));
    }
    final Object? d = j['duration'];
    return Info(
      (j['title'] ?? j['fulltitle'] ?? 'بدون عنوان').toString(),
      (j['thumbnail'] ?? '').toString(),
      (j['extractor_key'] ?? j['extractor'] ?? '').toString(),
      (j['uploader'] ?? j['channel'] ?? '').toString(),
      d is num ? d.toInt() : 0,
      opts,
    );
  }

  // التنزيل
  void start(Task t) {
    tasks.add(t);
    _save();
    _notify();
    _run(t);
  }

  void resume(Task t) {
    if (t.st == St.paused || t.st == St.waiting || t.st == St.failed) {
      t.err = '';
      _run(t);
    }
  }

  Future<void> pause(Task t) async {
    _stop[t.id] = 'paused';
    t.st = St.paused;
    _notify();
    if (t.direct) {
      _clients[t.id]?.close(force: true);
    } else {
      await Native.pause(t.id);
    }
  }

  Future<void> cancel(Task t) async {
    _stop[t.id] = 'cancelled';
    if (t.direct) {
      _clients[t.id]?.close(force: true);
      try {
        final Directory d = await getTemporaryDirectory();
        final File f = File('${d.path}/jesi_${t.id}.part');
        if (await f.exists()) await f.delete();
      } catch (_) {}
    } else {
      await Native.cancel(t.id);
    }
    tasks.remove(t);
    _save();
    _notify();
  }

  void removeTask(Task t) {
    tasks.remove(t);
    _save();
    _notify();
  }

  void clearFinished() {
    tasks.removeWhere((Task t) => t.st == St.done);
    _save();
    _notify();
  }

  Future<void> _run(Task t) async {
    if (_active.contains(t.id)) return;
    _active.add(t.id);
    _stop.remove(t.id);
    t.st = St.running;
    t.err = '';
    _notify();
    bool again = false;
    try {
      Map<String, dynamic> r;
      if (t.direct) {
        r = await _direct(t);
      } else {
        r = await Native.download(<String, dynamic>{
          'id': t.id,
          'url': t.url,
          'format': t.format,
          'audio': t.audio,
          'mode': t.mode,
          'title': t.title,
        });
      }
      t.st = St.done;
      t.pct = 1;
      t.res = r;
      library.insert(0, <String, dynamic>{...r, 'ts': DateTime.now().millisecondsSinceEpoch});
      HapticFeedback.mediumImpact();
    } on PlatformException catch (e) {
      if (e.code == 'cancelled') {
        tasks.remove(t);
      } else if (e.code == 'paused') {
        t.st = online ? St.paused : St.waiting;
      } else if (e.code == 'failed' && t.mode == 'fast' && !t.fell) {
        t.fell = true;
        t.mode = 'classic';
        t.note = 'تم التحويل تلقائياً للوضع الكلاسيكي لأن المصدر لم يدعم الوضع السريع.';
        again = true;
      } else {
        t.st = St.failed;
        t.err = friendly(e.message ?? e.code);
      }
    } catch (e) {
      final String? why = _stop[t.id];
      if (why == 'cancelled') {
        tasks.remove(t);
      } else if (why == 'paused') {
        t.st = online ? St.paused : St.waiting;
      } else if (!online) {
        t.st = St.waiting;
      } else {
        t.st = St.failed;
        t.err = friendly(e.toString());
      }
    } finally {
      _active.remove(t.id);
      _save();
      _notify();
    }
    if (again) await _run(t);
  }

  Future<Map<String, dynamic>> _direct(Task t) async {
    final Directory dir = await getTemporaryDirectory();
    final File part = File('${dir.path}/jesi_${t.id}.part');
    int have = await part.exists() ? await part.length() : 0;
    final HttpClient c = HttpClient()..connectionTimeout = const Duration(seconds: 25);
    _clients[t.id] = c;
    try {
      final HttpClientRequest rq = await c.getUrl(Uri.parse(t.url));
      if (have > 0) rq.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
      final HttpClientResponse rs = await rq.close();
      if (rs.statusCode >= 400) throw HttpException('HTTP ${rs.statusCode}');
      final bool partial = rs.statusCode == 206;
      if (!partial) have = 0;
      final int total = rs.contentLength > 0 ? rs.contentLength + have : 0;
      t.size = total > 0 ? fmtBytes(total) : '—';
      final IOSink sink = part.openWrite(mode: partial ? FileMode.append : FileMode.write);
      int got = have;
      int lastBytes = got;
      final Stopwatch sw = Stopwatch()..start();
      int lastMs = 0;
      try {
        await for (final List<int> chunk in rs) {
          sink.add(chunk);
          got += chunk.length;
          final int ms = sw.elapsedMilliseconds;
          if (ms - lastMs > 500) {
            final double bps = (got - lastBytes) * 1000 / (ms - lastMs);
            t.speed = '${fmtBytes(bps)}/s';
            if (total > 0) {
              t.pct = got / total;
              final int left = ((total - got) / (bps > 0 ? bps : 1)).round();
              t.eta = fmtDur(left);
            }
            lastMs = ms;
            lastBytes = got;
            _notify();
          }
        }
      } finally {
        await sink.close();
      }
      final File out = File('${dir.path}/${t.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')}');
      if (await out.exists()) await out.delete();
      await part.rename(out.path);
      return await Native.publish(out.path);
    } finally {
      c.close(force: true);
      _clients.remove(t.id);
    }
  }

  final RegExp _rSize = RegExp(r'of\s+~?\s*([\d.]+\s*[KMGT]?i?B)');
  final RegExp _rSpeed = RegExp(r'at\s+([\d.]+\s*[KMGT]?i?B/s)');

  void _onProgress(String id, double p, int eta, String line) {
    final Task? t = _byId(id);
    if (t == null || !t.active) return;
    if (line.contains('[Merger]') || line.contains('[ExtractAudio]') || line.contains('[VideoRemuxer]') || line.contains('[Fixup')) {
      t.st = St.processing;
      t.pct = 1;
      t.speed = '—';
      t.eta = '—';
    } else {
      t.st = St.running;
      if (p >= 0 && p <= 100) t.pct = p / 100;
      final RegExpMatch? s = _rSize.firstMatch(line);
      if (s != null) t.size = s.group(1)!.trim();
      final RegExpMatch? sp = _rSpeed.firstMatch(line);
      if (sp != null) t.speed = sp.group(1)!.trim();
      if (eta >= 0) t.eta = fmtDur(eta);
    }
    _notify();
  }

  void _onNet(List<ConnectivityResult> r) {
    final bool on = !r.contains(ConnectivityResult.none);
    if (on == online) return;
    online = on;
    if (!on) {
      for (final Task t in List<Task>.from(tasks)) {
        if (t.st == St.running || t.st == St.processing) {
          t.st = St.waiting;
          t.err = 'التنزيل متوقف بسبب انقطاع الشبكة. التقدم محفوظ.';
          if (t.direct) {
            _stop[t.id] = 'paused';
            _clients[t.id]?.close(force: true);
          } else {
            _stop[t.id] = 'paused';
            Native.pause(t.id);
          }
        }
      }
    } else {
      for (final Task t in List<Task>.from(tasks)) {
        if (t.st == St.waiting) {
          t.err = '';
          _run(t);
        }
      }
    }
    _notify();
  }

  // الملفات
  Future<void> refreshLibrary() async {
    final List<Map<String, dynamic>> gone = <Map<String, dynamic>>[];
    for (final Map<String, dynamic> m in library) {
      if (!await Native.exists((m['uri'] ?? '') as String)) gone.add(m);
    }
    if (gone.isNotEmpty) {
      library.removeWhere((Map<String, dynamic> m) => gone.contains(m));
      _save();
      _notify();
    }
  }

  Future<void> deleteFile(Map<String, dynamic> m) async {
    final String uri = (m['uri'] ?? '') as String;
    await Native.delete(uri);
    library.remove(m);
    tasks.removeWhere((Task t) => t.res != null && t.res!['uri'] == uri);
    _save();
    _notify();
  }
}

// ───────────────────────── الخلفية المتحركة + الأوراق ─────────────────────────

class Petal {
  final double x, speed, size, phase, sway;
  final int rot, swayK;
  const Petal(this.x, this.speed, this.size, this.phase, this.sway, this.rot, this.swayK);
}

class PetalPainter extends CustomPainter {
  final Animation<double> anim;
  final List<Petal> petals;
  PetalPainter(this.anim, this.petals) : super(repaint: anim);

  @override
  void paint(Canvas canvas, Size size) {
    final double t = anim.value;
    final Paint fill = Paint()..style = PaintingStyle.fill;
    for (final Petal p in petals) {
      final double prog = (t * p.speed + p.phase) % 1.0;
      final double y = prog * (size.height + 2 * p.size) - p.size;
      final double x = p.x * size.width + math.sin(t * 2 * math.pi * p.swayK + p.phase * 6.28) * p.sway;
      final double a = math.sin(prog * math.pi).clamp(0.0, 1.0).toDouble();
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(t * 2 * math.pi * p.rot + p.phase * 6.28);
      final double s = p.size;
      final Path path = Path()
        ..moveTo(0, -s)
        ..quadraticBezierTo(s * 0.9, -s * 0.2, 0, s)
        ..quadraticBezierTo(-s * 0.9, -s * 0.2, 0, -s)
        ..close();
      fill.color = Color.fromRGBO(255, 150, 200, 0.55 * a);
      canvas.drawPath(path, fill);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant PetalPainter old) => false;
}

class Backdrop extends StatefulWidget {
  const Backdrop({super.key});
  @override
  State<Backdrop> createState() => _BackdropState();
}

class _BackdropState extends State<Backdrop> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  VideoPlayerController? vc;
  bool ready = false;
  late final AnimationController anim;
  late final List<Petal> petals;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    anim = AnimationController(vsync: this, duration: const Duration(seconds: 24))..repeat();
    final math.Random r = math.Random(7);
    petals = List<Petal>.generate(
      7,
      (int i) => Petal(r.nextDouble(), (1 + r.nextInt(2)).toDouble(), 7 + r.nextDouble() * 6, r.nextDouble(),
          10 + r.nextDouble() * 18, 1 + r.nextInt(3), 2 + r.nextInt(3)),
    );
    _initVideo();
  }

  Future<void> _initVideo() async {
    try {
      final VideoPlayerController c =
          VideoPlayerController.asset('assets/bg.mp4', videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true));
      await c.initialize();
      await c.setVolume(0);
      await c.setLooping(true);
      await c.play();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() {
        vc = c;
        ready = true;
      });
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      vc?.play();
      anim.repeat();
    } else if (s == AppLifecycleState.paused) {
      vc?.pause();
      anim.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    anim.dispose();
    vc?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final VideoPlayerController? c = vc;
    return Stack(fit: StackFit.expand, children: <Widget>[
      const ColoredBox(color: kBlack),
      if (ready && c != null)
        ColorFiltered(
          colorFilter: const ColorFilter.mode(Color(0xB3E91E78), BlendMode.color),
          child: FittedBox(
            fit: BoxFit.cover,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(width: c.value.size.width, height: c.value.size.height, child: VideoPlayer(c)),
          ),
        ),
      const ColoredBox(color: Color(0x99000000)),
      const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[Color(0x80600A2E), Color(0x00000000), Color(0xA6300616)],
          ),
        ),
      ),
      IgnorePointer(child: RepaintBoundary(child: CustomPaint(painter: PetalPainter(anim, petals), size: Size.infinite))),
    ]);
  }
}

// ───────────────────────── عناصر واجهة ─────────────────────────

class Glass extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  const Glass({super.key, required this.child, this.padding = const EdgeInsets.all(14), this.onTap});

  @override
  Widget build(BuildContext context) {
    final Widget box = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: const Color(0x33100208),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0x33FFB3D1)),
        boxShadow: const <BoxShadow>[BoxShadow(color: Color(0x33000000), blurRadius: 18, offset: Offset(0, 6))],
      ),
      child: child,
    );
    if (onTap == null) return box;
    return GestureDetector(onTap: onTap, child: box);
  }
}

class GlowButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool busy;
  const GlowButton({super.key, required this.label, required this.icon, required this.onTap, this.busy = false});
  @override
  State<GlowButton> createState() => _GlowButtonState();
}

class _GlowButtonState extends State<GlowButton> {
  bool down = false;
  @override
  Widget build(BuildContext context) {
    final bool on = widget.onTap != null && !widget.busy;
    return GestureDetector(
      onTapDown: on ? (_) => setState(() => down = true) : null,
      onTapCancel: () => setState(() => down = false),
      onTapUp: (_) => setState(() => down = false),
      onTap: on
          ? () {
              HapticFeedback.lightImpact();
              widget.onTap!();
            }
          : null,
      child: AnimatedScale(
        scale: down ? 0.96 : 1,
        duration: const Duration(milliseconds: 120),
        child: AnimatedOpacity(
          opacity: on ? 1 : 0.55,
          duration: const Duration(milliseconds: 200),
          child: Container(
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: const LinearGradient(colors: <Color>[kWine, kPink]),
              boxShadow: const <BoxShadow>[BoxShadow(color: Color(0x66FF5FA2), blurRadius: 22, spreadRadius: 0)],
            ),
            child: widget.busy
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                : Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
                    Icon(widget.icon, color: Colors.white),
                    const SizedBox(width: 8),
                    Text(widget.label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                  ]),
          ),
        ),
      ),
    );
  }
}

class Reveal extends StatefulWidget {
  final Widget child;
  final int delay;
  const Reveal({super.key, required this.child, this.delay = 0});
  @override
  State<Reveal> createState() => _RevealState();
}

class _RevealState extends State<Reveal> with SingleTickerProviderStateMixin {
  late final AnimationController c;
  late final CurvedAnimation cur;

  @override
  void initState() {
    super.initState();
    c = AnimationController(vsync: this, duration: const Duration(milliseconds: 520));
    cur = CurvedAnimation(parent: c, curve: Curves.easeOutCubic);
    Future<void>.delayed(Duration(milliseconds: widget.delay), () {
      if (mounted) c.forward();
    });
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: cur,
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 0.08), end: Offset.zero).animate(cur),
          child: widget.child,
        ),
      );
}

Widget kindIcon(String kind, {double size = 26}) {
  IconData i = Icons.insert_drive_file_rounded;
  if (kind == 'video') i = Icons.movie_rounded;
  if (kind == 'audio') i = Icons.music_note_rounded;
  if (kind == 'image') i = Icons.image_rounded;
  return Icon(i, color: kSoftPink, size: size);
}

Widget thumbBox(String url, {double w = 72, double h = 54, String kind = 'video'}) {
  return ClipRRect(
    borderRadius: BorderRadius.circular(12),
    child: SizedBox(
      width: w,
      height: h,
      child: url.isEmpty
          ? ColoredBox(color: kDeepWine, child: Center(child: kindIcon(kind)))
          : Image.network(url, fit: BoxFit.cover,
              errorBuilder: (BuildContext c, Object e, StackTrace? s) => ColoredBox(color: kDeepWine, child: Center(child: kindIcon(kind)))),
    ),
  );
}

// ───────────────────────── التطبيق ─────────────────────────

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  await app.init();
  runApp(const JesiApp());
}

class JesiApp extends StatefulWidget {
  const JesiApp({super.key});
  @override
  State<JesiApp> createState() => _JesiAppState();
}

class _JesiAppState extends State<JesiApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => app.checkShare());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) app.checkShare();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = ColorScheme.fromSeed(seedColor: kPink, brightness: Brightness.dark).copyWith(primary: kPink);
    return MaterialApp(
      title: 'JESI',
      debugShowCheckedModeBanner: false,
      navigatorKey: navKey,
      scaffoldMessengerKey: msgKey,
      locale: const Locale('ar'),
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: cs,
        scaffoldBackgroundColor: Colors.transparent,
        canvasColor: kBlack,
      ),
      builder: (BuildContext c, Widget? child) => Directionality(
        textDirection: TextDirection.rtl,
        child: Stack(fit: StackFit.expand, children: <Widget>[const Backdrop(), if (child != null) child]),
      ),
      home: const Shell(),
    );
  }
}

class Shell extends StatelessWidget {
  const Shell({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: app.tab,
      builder: (BuildContext c, int i, Widget? w) {
        const List<IconData> icons = <IconData>[Icons.home_rounded, Icons.downloading_rounded, Icons.folder_rounded, Icons.settings_rounded];
        const List<String> names = <String>['الرئيسية', 'التنزيلات', 'الملفات', 'الإعدادات'];
        final List<Widget> pages = <Widget>[const HomePage(), const DownloadsPage(), const LibraryPage(), const SettingsPage()];
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            bottom: false,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 320),
              switchInCurve: Curves.easeOutCubic,
              transitionBuilder: (Widget ch, Animation<double> a) => FadeTransition(
                opacity: a,
                child: SlideTransition(position: Tween<Offset>(begin: const Offset(0, 0.03), end: Offset.zero).animate(a), child: ch),
              ),
              child: KeyedSubtree(key: ValueKey<int>(i), child: pages[i]),
            ),
          ),
          bottomNavigationBar: ClipRect(
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
              child: Container(
                padding: EdgeInsets.fromLTRB(10, 8, 10, 8 + MediaQuery.of(context).padding.bottom),
                decoration: const BoxDecoration(
                  color: Color(0x66100208),
                  border: Border(top: BorderSide(color: Color(0x33FFB3D1))),
                ),
                child: Row(
                  children: List<Widget>.generate(4, (int k) {
                    final bool sel = k == i;
                    return Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          HapticFeedback.selectionClick();
                          app.tab.value = k;
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 260),
                          curve: Curves.easeOutCubic,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            color: sel ? const Color(0x33FF5FA2) : Colors.transparent,
                            boxShadow: sel ? const <BoxShadow>[BoxShadow(color: Color(0x33FF5FA2), blurRadius: 14)] : null,
                          ),
                          child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
                            Icon(icons[k], color: sel ? kPink : Colors.white54),
                            const SizedBox(height: 2),
                            Text(names[k], style: TextStyle(fontSize: 11, color: sel ? kPink : Colors.white54)),
                          ]),
                        ),
                      ),
                    );
                  }),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ───────────────────────── الرئيسية ─────────────────────────

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  void go(BuildContext c) {
    final String? u = extractUrl(app.urlCtl.text);
    if (u == null || Uri.tryParse(u)?.hasAuthority != true) {
      toast('الصق رابطاً صحيحاً أولاً');
      return;
    }
    FocusScope.of(c).unfocus();
    app.openPreview(u);
  }

  Future<void> paste(BuildContext c) async {
    final ClipboardData? d = await Clipboard.getData('text/plain');
    final String t = d?.text ?? '';
    if (t.trim().isEmpty) {
      toast('الحافظة فارغة');
      return;
    }
    app.urlCtl.text = t.trim();
    if (c.mounted) go(c);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (BuildContext c, Widget? w) {
        final List<Map<String, dynamic>> recent = app.library.take(3).toList();
        return ListView(padding: const EdgeInsets.fromLTRB(18, 16, 18, 24), children: <Widget>[
          Reveal(
            child: Row(children: <Widget>[
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  gradient: const LinearGradient(colors: <Color>[kWine, kPink]),
                  boxShadow: const <BoxShadow>[BoxShadow(color: Color(0x66FF5FA2), blurRadius: 20)],
                ),
                child: const Icon(Icons.download_rounded, color: Colors.white, size: 32),
              ),
              const SizedBox(width: 14),
              const Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                Text('JESI', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900, letterSpacing: 3)),
                Text('تنزيل بدون إعلانات', style: TextStyle(color: kSoftPink)),
              ]),
            ]),
          ),
          const SizedBox(height: 22),
          Reveal(
            delay: 90,
            child: Glass(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
                TextField(
                  controller: app.urlCtl,
                  keyboardType: TextInputType.url,
                  textDirection: TextDirection.ltr,
                  onSubmitted: (String s) => go(c),
                  decoration: InputDecoration(
                    hintText: 'الصق رابط الفيديو أو الصورة أو الصوت',
                    hintTextDirection: TextDirection.rtl,
                    prefixIcon: const Icon(Icons.link_rounded, color: kPink),
                    suffixIcon: IconButton(onPressed: () => app.urlCtl.clear(), icon: const Icon(Icons.close_rounded, size: 20)),
                    filled: true,
                    fillColor: const Color(0x33000000),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                  ),
                ),
                const SizedBox(height: 12),
                GlowButton(label: 'تحليل الرابط', icon: Icons.search_rounded, onTap: () => go(c)),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () => paste(c),
                  icon: const Icon(Icons.content_paste_rounded, color: kSoftPink),
                  label: const Text('لصق من الحافظة وتحليل مباشرة', style: TextStyle(color: kSoftPink)),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 14),
          Reveal(
            delay: 170,
            child: Row(children: <Widget>[
              for (final List<Object> s in <List<Object>>[
                <Object>[Icons.downloading_rounded, 'التنزيلات', 1],
                <Object>[Icons.folder_rounded, 'الملفات', 2],
                <Object>[Icons.settings_rounded, 'الإعدادات', 3],
              ])
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Glass(
                      onTap: () => app.tab.value = s[2] as int,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Column(children: <Widget>[
                        Icon(s[0] as IconData, color: kPink),
                        const SizedBox(height: 6),
                        Text(s[1] as String, style: const TextStyle(fontSize: 12)),
                      ]),
                    ),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 22),
          Reveal(
            delay: 240,
            child: Row(children: <Widget>[
              const Text('آخر التنزيلات', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const Spacer(),
              if (recent.isNotEmpty) TextButton(onPressed: () => app.tab.value = 2, child: const Text('عرض الكل')),
            ]),
          ),
          const SizedBox(height: 8),
          if (recent.isEmpty)
            const Reveal(delay: 300, child: Glass(child: Center(child: Padding(padding: EdgeInsets.all(10), child: Text('لا توجد تنزيلات بعد', style: TextStyle(color: Colors.white60))))))
          else
            for (int i = 0; i < recent.length; i++)
              Reveal(delay: 300 + i * 70, child: Padding(padding: const EdgeInsets.only(bottom: 8), child: FileTile(item: recent[i]))),
        ]);
      },
    );
  }
}

class FileTile extends StatelessWidget {
  final Map<String, dynamic> item;
  const FileTile({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    final String kind = (item['kind'] ?? 'file') as String;
    final String uri = (item['uri'] ?? '') as String;
    final String mime = (item['mime'] ?? '*/*') as String;
    final int size = ((item['size'] ?? 0) as num).toInt();
    final int ts = ((item['ts'] ?? 0) as num).toInt();
    return Glass(
      onTap: () => Native.open(uri, mime),
      padding: const EdgeInsets.all(10),
      child: Row(children: <Widget>[
        kind == 'image' ? thumbBox('', kind: 'image', w: 52, h: 52) : thumbBox('', kind: kind, w: 52, h: 52),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Text((item['name'] ?? '') as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 3),
            Text('${fmtBytes(size)} • ${kind == 'video' ? 'فيديو' : kind == 'audio' ? 'صوت' : kind == 'image' ? 'صورة' : 'ملف'} • ${fmtDate(ts)}',
                style: const TextStyle(color: Colors.white60, fontSize: 12)),
          ]),
        ),
        PopupMenuButton<String>(
          onSelected: (String v) async {
            if (v == 'open') await Native.open(uri, mime);
            if (v == 'share') await Native.share(uri, mime);
            if (v == 'delete') {
              final bool? ok = await showDialog<bool>(
                context: context,
                builder: (BuildContext d) => AlertDialog(
                  title: const Text('حذف الملف؟'),
                  content: const Text('سيُحذف الملف نهائياً من الجهاز.'),
                  actions: <Widget>[
                    TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('إلغاء')),
                    TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('حذف')),
                  ],
                ),
              );
              if (ok == true) await app.deleteFile(item);
            }
          },
          itemBuilder: (BuildContext c) => const <PopupMenuEntry<String>>[
            PopupMenuItem<String>(value: 'open', child: Text('فتح')),
            PopupMenuItem<String>(value: 'share', child: Text('مشاركة')),
            PopupMenuItem<String>(value: 'delete', child: Text('حذف')),
          ],
        ),
      ]),
    );
  }
}

// ───────────────────────── المعاينة ─────────────────────────

class PreviewPage extends StatefulWidget {
  final String url;
  const PreviewPage({super.key, required this.url});
  @override
  State<PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<PreviewPage> {
  Info? info;
  String? error;
  bool loading = true;
  int sel = 0;
  String mode = app.mode;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final Info i = await app.analyze(widget.url);
      if (i.opts.isEmpty) throw 'لم يوفّر المصدر خيارات تنزيل قابلة للاستخدام.';
      int pick = 0;
      for (int k = 0; k < i.opts.length; k++) {
        if (!i.opts[k].isAudio && i.opts[k].label.startsWith('720')) pick = k;
      }
      if (pick == 0) {
        for (int k = 0; k < i.opts.length; k++) {
          if (!i.opts[k].isAudio) pick = k;
        }
      }
      info = i;
      sel = pick;
    } catch (e) {
      error = e.toString();
    }
    if (mounted) setState(() => loading = false);
  }

  void begin() {
    final Info i = info!;
    final Opt o = i.opts[sel];
    if (app.hasActive(widget.url, o.sel)) {
      toast('هذا التنزيل قيد التنفيذ بالفعل');
      return;
    }
    final Task t = Task(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      url: widget.url,
      title: i.title,
      thumb: i.thumb,
      format: o.sel,
      audio: o.audio,
      mode: o.direct ? 'classic' : mode,
      direct: o.direct,
    );
    if (o.bytes != null) t.size = fmtBytes(o.bytes!);
    app.start(t);
    app.tab.value = 1;
    Navigator.of(context).pop();
    toast('بدأ التنزيل');
  }

  @override
  Widget build(BuildContext context) {
    final Info i = info ?? const Info('', '', '', '', 0, <Opt>[]);
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(backgroundColor: Colors.transparent, title: const Text('معاينة الرابط')),
      body: loading
          ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
              CircularProgressIndicator(color: kPink),
              SizedBox(height: 14),
              Text('جارٍ تحليل الرابط…'),
            ]))
          : error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Glass(
                      child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
                        const Icon(Icons.error_rounded, color: kPink, size: 40),
                        const SizedBox(height: 10),
                        Text(error!, textAlign: TextAlign.center),
                        const SizedBox(height: 14),
                        GlowButton(label: 'إعادة المحاولة', icon: Icons.refresh_rounded, onTap: load),
                      ]),
                    ),
                  ),
                )
              : ListView(padding: const EdgeInsets.fromLTRB(18, 4, 18, 28), children: <Widget>[
                  Reveal(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: AspectRatio(aspectRatio: 16 / 9, child: thumbBox(i.thumb, w: double.infinity, h: double.infinity)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Reveal(delay: 70, child: Text(i.title, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold))),
                  const SizedBox(height: 8),
                  Reveal(
                    delay: 120,
                    child: Wrap(spacing: 8, runSpacing: 6, children: <Widget>[
                      if (i.site.isNotEmpty) Chip(label: Text(i.site), avatar: const Icon(Icons.public_rounded, size: 16)),
                      if (i.dur > 0) Chip(label: Text(fmtDur(i.dur)), avatar: const Icon(Icons.timer_rounded, size: 16)),
                      if (i.uploader.isNotEmpty) Chip(label: Text(i.uploader), avatar: const Icon(Icons.person_rounded, size: 16)),
                    ]),
                  ),
                  const SizedBox(height: 10),
                  for (int k = 0; k < i.opts.length; k++)
                    Reveal(
                      delay: 160 + k * 40,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: GestureDetector(
                          onTap: () {
                            HapticFeedback.selectionClick();
                            setState(() => sel = k);
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 220),
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: const Color(0x33100208),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: sel == k ? kPink : const Color(0x33FFB3D1), width: sel == k ? 1.6 : 1),
                              boxShadow: sel == k ? const <BoxShadow>[BoxShadow(color: Color(0x44FF5FA2), blurRadius: 16)] : null,
                            ),
                            child: Row(children: <Widget>[
                              Icon(i.opts[k].isAudio ? Icons.music_note_rounded : Icons.movie_rounded, color: sel == k ? kPink : Colors.white60),
                              const SizedBox(width: 10),
                              Expanded(child: Text(i.opts[k].label, style: const TextStyle(fontWeight: FontWeight.w600))),
                              if (i.opts[k].bytes != null) Text('~ ${fmtBytes(i.opts[k].bytes!)}', style: const TextStyle(color: Colors.white60, fontSize: 12)),
                              const SizedBox(width: 8),
                              Icon(sel == k ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded, color: sel == k ? kPink : Colors.white38, size: 20),
                            ]),
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 10),
                  if (!i.opts[sel].direct) ...<Widget>[
                    const Text('وضع التنزيل', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    SegmentedButton<String>(
                      segments: const <ButtonSegment<String>>[
                        ButtonSegment<String>(value: 'classic', label: Text('كلاسيكي (مستقر)'), icon: Icon(Icons.shield_rounded)),
                        ButtonSegment<String>(value: 'fast', label: Text('سريع'), icon: Icon(Icons.bolt_rounded)),
                      ],
                      selected: <String>{mode},
                      onSelectionChanged: (Set<String> s) => setState(() => mode = s.first),
                    ),
                    const SizedBox(height: 6),
                    Text(mode == 'fast' ? 'اتصالات متوازية. إن لم يدعمها المصدر يتحول التطبيق تلقائياً للكلاسيكي ويخبرك.' : 'الأفضل للاتصالات الضعيفة.',
                        style: const TextStyle(color: Colors.white60, fontSize: 12)),
                  ] else
                    const Text('تنزيل مباشر للملف (الوضع السريع غير متاح لهذا الرابط).', style: TextStyle(color: Colors.white60, fontSize: 12)),
                  const SizedBox(height: 16),
                  GlowButton(label: 'بدء التنزيل', icon: Icons.download_rounded, onTap: begin),
                ]),
    );
  }
}

// ───────────────────────── التنزيلات ─────────────────────────

class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key});

  static const Map<St, String> names = <St, String>{
    St.queued: 'في الانتظار',
    St.running: 'جارٍ التنزيل',
    St.paused: 'متوقف مؤقتاً',
    St.waiting: 'بانتظار الشبكة',
    St.processing: 'جارٍ المعالجة',
    St.done: 'اكتمل',
    St.failed: 'فشل',
  };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (BuildContext c, Widget? w) {
        final List<Task> list = app.tasks.reversed.toList();
        return ListView(padding: const EdgeInsets.fromLTRB(18, 16, 18, 24), children: <Widget>[
          Row(children: <Widget>[
            const Text('التنزيلات', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
            const Spacer(),
            if (list.any((Task t) => t.st == St.done)) TextButton(onPressed: app.clearFinished, child: const Text('مسح المكتملة')),
          ]),
          if (!app.online)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Glass(child: Row(children: <Widget>[Icon(Icons.wifi_off_rounded, color: kPink), SizedBox(width: 10), Expanded(child: Text('لا يوجد اتصال. ستُستأنف التنزيلات تلقائياً عند عودته.'))])),
            ),
          const SizedBox(height: 10),
          if (list.isEmpty)
            const Padding(padding: EdgeInsets.only(top: 80), child: Center(child: Text('لا توجد تنزيلات', style: TextStyle(color: Colors.white60))))
          else
            for (int i = 0; i < list.length; i++)
              Padding(padding: const EdgeInsets.only(bottom: 10), child: Reveal(delay: i * 40, child: TaskCard(task: list[i]))),
        ]);
      },
    );
  }
}

class TaskCard extends StatelessWidget {
  final Task task;
  const TaskCard({super.key, required this.task});

  @override
  Widget build(BuildContext context) {
    final Task t = task;
    final bool busy = t.st == St.running || t.st == St.processing || t.st == St.queued;
    final String kind = t.res != null ? ((t.res!['kind'] ?? 'video') as String) : (t.audio != null ? 'audio' : 'video');
    return Glass(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Row(children: <Widget>[
          thumbBox(t.thumb, kind: kind),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text(t.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(DownloadsPage.names[t.st] ?? '', style: TextStyle(color: t.st == St.failed ? Colors.redAccent : kSoftPink, fontSize: 12)),
            ]),
          ),
        ]),
        if (t.st != St.done && t.st != St.failed) ...<Widget>[
          const SizedBox(height: 10),
          TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: t.pct),
            duration: const Duration(milliseconds: 400),
            builder: (BuildContext c, double v, Widget? w) => LinearProgressIndicator(
              value: t.st == St.processing ? null : v,
              minHeight: 7,
              borderRadius: BorderRadius.circular(8),
              color: kPink,
              backgroundColor: const Color(0x33FFFFFF),
            ),
          ),
          const SizedBox(height: 8),
          Row(children: <Widget>[
            Text('${(t.pct * 100).toStringAsFixed(0)}%', style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(width: 12),
            Text('السرعة ${t.speed}', style: const TextStyle(color: Colors.white70, fontSize: 12)),
            const SizedBox(width: 12),
            Text('المتبقي ${t.eta}', style: const TextStyle(color: Colors.white70, fontSize: 12)),
            const Spacer(),
            Text(t.size, style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ]),
        ],
        if (t.err.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(t.err, style: const TextStyle(color: Colors.white70, fontSize: 12))),
        if (t.note.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(t.note, style: const TextStyle(color: kSoftPink, fontSize: 12))),
        const SizedBox(height: 6),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: <Widget>[
          if (busy) TextButton.icon(onPressed: () => app.pause(t), icon: const Icon(Icons.pause_rounded), label: const Text('إيقاف مؤقت')),
          if (t.st == St.paused || t.st == St.waiting) TextButton.icon(onPressed: () => app.resume(t), icon: const Icon(Icons.play_arrow_rounded), label: const Text('استئناف')),
          if (t.st == St.failed) TextButton.icon(onPressed: () => app.resume(t), icon: const Icon(Icons.refresh_rounded), label: const Text('إعادة المحاولة')),
          if (t.st == St.done && t.res != null) ...<Widget>[
            TextButton.icon(onPressed: () => Native.open(t.res!['uri'] as String, (t.res!['mime'] ?? '*/*') as String), icon: const Icon(Icons.open_in_new_rounded), label: const Text('فتح')),
            TextButton.icon(onPressed: () => Native.share(t.res!['uri'] as String, (t.res!['mime'] ?? '*/*') as String), icon: const Icon(Icons.share_rounded), label: const Text('مشاركة')),
          ],
          if (t.st == St.done || t.st == St.failed)
            IconButton(onPressed: () => app.removeTask(t), icon: const Icon(Icons.close_rounded))
          else
            IconButton(onPressed: () => app.cancel(t), icon: const Icon(Icons.stop_circle_rounded, color: kPink)),
        ]),
      ]),
    );
  }
}

// ───────────────────────── الملفات ─────────────────────────

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  int tab = 0;

  @override
  void initState() {
    super.initState();
    app.refreshLibrary();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (BuildContext c, Widget? w) {
        const List<String> names = <String>['الكل', 'فيديو', 'صوت', 'صور'];
        const List<String> kinds = <String>['', 'video', 'audio', 'image'];
        final List<Map<String, dynamic>> list = app.library.where((Map<String, dynamic> m) => tab == 0 || m['kind'] == kinds[tab]).toList();
        return RefreshIndicator(
          onRefresh: app.refreshLibrary,
          child: ListView(padding: const EdgeInsets.fromLTRB(18, 16, 18, 24), children: <Widget>[
            const Text('الملفات', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            const Text('Movies / Music / Pictures ← JESI', textDirection: TextDirection.ltr, style: TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 10),
            Wrap(spacing: 8, children: List<Widget>.generate(4, (int i) => ChoiceChip(label: Text(names[i]), selected: tab == i, onSelected: (bool v) => setState(() => tab = i)))),
            const SizedBox(height: 10),
            if (list.isEmpty)
              const Padding(padding: EdgeInsets.only(top: 80), child: Center(child: Text('لا توجد ملفات في هذا القسم', style: TextStyle(color: Colors.white60))))
            else
              for (int i = 0; i < list.length; i++) Padding(padding: const EdgeInsets.only(bottom: 8), child: FileTile(item: list[i])),
          ]),
        );
      },
    );
  }
}

// ───────────────────────── الإعدادات ─────────────────────────

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool updating = false;

  Future<void> update() async {
    setState(() => updating = true);
    try {
      final String r = await Native.updateEngine();
      toast('تم تحديث المحرك: $r');
    } on PlatformException catch (e) {
      toast(friendly(e.message ?? 'فشل التحديث'));
    }
    if (mounted) setState(() => updating = false);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (BuildContext c, Widget? w) => ListView(padding: const EdgeInsets.fromLTRB(18, 16, 18, 24), children: <Widget>[
        const Text('الإعدادات', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
        const SizedBox(height: 14),
        Reveal(
          child: Glass(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              const Text('وضع التنزيل الافتراضي', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              SegmentedButton<String>(
                segments: const <ButtonSegment<String>>[
                  ButtonSegment<String>(value: 'classic', label: Text('كلاسيكي'), icon: Icon(Icons.shield_rounded)),
                  ButtonSegment<String>(value: 'fast', label: Text('سريع'), icon: Icon(Icons.bolt_rounded)),
                ],
                selected: <String>{app.mode},
                onSelectionChanged: (Set<String> s) => app.setMode(s.first),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        Reveal(
          delay: 70,
          child: Glass(
            child: Column(children: <Widget>[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('تحديث المحرك تلقائياً (مرة يومياً)'),
                subtitle: const Text('المواقع تتغير باستمرار، والتحديث يصلح التعطل', style: TextStyle(fontSize: 12)),
                value: app.autoUpdate,
                onChanged: app.setAutoUpdate,
              ),
              const SizedBox(height: 6),
              GlowButton(label: 'تحديث المحرك الآن', icon: Icons.system_update_alt_rounded, onTap: update, busy: updating),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        const Reveal(
          delay: 140,
          child: Glass(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text('مكان الحفظ', style: TextStyle(fontWeight: FontWeight.bold)),
              SizedBox(height: 6),
              Text('الفيديو: Movies/JESI\nالصوت: Music/JESI\nالصور: Pictures/JESI\nأخرى: Download/JESI', textDirection: TextDirection.ltr, style: TextStyle(color: Colors.white70)),
              SizedBox(height: 6),
              Text('أندرويد الحديث يمنع اختيار مجلد حر دون نافذة نظام، لذلك الحفظ يتم في هذه المجلدات عبر MediaStore.', style: TextStyle(color: Colors.white54, fontSize: 12)),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        const Reveal(
          delay: 210,
          child: Glass(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text('JESI Downloader', style: TextStyle(fontWeight: FontWeight.bold)),
              SizedBox(height: 4),
              Text('الإصدار $kVersion • بدون إعلانات', style: TextStyle(color: Colors.white70)),
              SizedBox(height: 4),
              Text('المحتوى الخاص أو المحمي أو الذي يتطلب تسجيل دخول لا يمكن تنزيله. احترم حقوق النشر وشروط المنصات.', style: TextStyle(color: Colors.white54, fontSize: 12)),
            ]),
          ),
        ),
      ]),
    );
  }
}
