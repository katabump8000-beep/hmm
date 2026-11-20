import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

const neon = Color(0xFF20E6C5);
const bg = Color(0xFF070B10);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Notice.init();
  runApp(const JesiApp());
}

class Notice {
  static final plugin = FlutterLocalNotificationsPlugin();
  static Future<void> init() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await plugin.initialize(const InitializationSettings(android: android));
    await plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  static Future<void> show(String title, String body, {int id = 1}) async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'jesi_downloads', 'JESI downloads',
        channelDescription: 'Download progress and status',
        importance: Importance.low,
        priority: Priority.low,
        ongoing: true,
        showProgress: true,
        maxProgress: 100,
        progress: 0,
      ),
    );
    await plugin.show(id, title, body, details);
  }

  static Future<void> done(String title, String body, {int id = 1}) async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'jesi_downloads', 'JESI downloads',
        channelDescription: 'Download completion',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        ongoing: false,
      ),
    );
    await plugin.show(id, title, body, details);
  }
}

class JesiApp extends StatelessWidget {
  const JesiApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'JESI Downloader',
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bg,
      colorScheme: const ColorScheme.dark(primary: neon, secondary: Color(0xFF6A7CFF)),
      useMaterial3: true,
      inputDecorationTheme: InputDecorationTheme(
        filled: true, fillColor: const Color(0xFF111923),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: Colors.white.withOpacity(.07))),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: neon)),
      ),
    ),
    home: const HomePage(),
  );
}

enum MediaKind { video, image, audio, other, page }

class LinkInfo {
  final String url, type, name;
  final int? length;
  final MediaKind kind;
  const LinkInfo(this.url, this.type, this.name, this.length, this.kind);
  String get label => switch (kind) {
    MediaKind.video => 'فيديو',
    MediaKind.image => 'صورة',
    MediaKind.audio => 'ملف صوتي',
    MediaKind.page => 'صفحة / رابط منصة',
    MediaKind.other => 'ملف آخر',
  };
}

MediaKind kindFrom(String? mime, String url) {
  final m = (mime ?? '').toLowerCase();
  if (m.startsWith('video/')) return MediaKind.video;
  if (m.startsWith('image/')) return MediaKind.image;
  if (m.startsWith('audio/')) return MediaKind.audio;
  if (m.contains('html')) return MediaKind.page;
  final p = Uri.tryParse(url)?.path.toLowerCase() ?? '';
  if (['.mp4','.mov','.m4v','.webm'].any(p.endsWith)) return MediaKind.video;
  if (['.jpg','.jpeg','.png','.webp','.gif'].any(p.endsWith)) return MediaKind.image;
  if (['.mp3','.m4a','.aac','.wav','.ogg'].any(p.endsWith)) return MediaKind.audio;
  return MediaKind.other;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  final urlCtrl = TextEditingController();
  final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 20), receiveTimeout: const Duration(minutes: 5), followRedirects: true, maxRedirects: 8));
  final secure = const FlutterSecureStorage();
  LinkInfo? info;
  bool inspecting = false, downloading = false, online = true;
  double progress = 0;
  String status = 'ضع رابطاً للفحص', speed = '—', error = '';
  StreamSubscription<List<ConnectivityResult>>? netSub;
  Timer? retryTimer;
  CancelToken? cancel;
  late final AnimationController pulse;

  @override
  void initState() {
    super.initState();
    pulse = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
    netSub = Connectivity().onConnectivityChanged.listen((r) {
      final now = !r.contains(ConnectivityResult.none);
      if (mounted) setState(() => online = now);
      if (now && downloading) _retryIfNeeded();
    });
  }

  @override
  void dispose() {
    retryTimer?.cancel(); netSub?.cancel(); pulse.dispose();
    urlCtrl.dispose();
    super.dispose();
  }

  String _cleanUrl(String raw) {
    final s = raw.trim();
    final u = Uri.tryParse(s.contains('://') ? s : 'https://$s');
    if (u == null || !u.hasAuthority || !['http','https'].contains(u.scheme)) {
      throw const FormatException('الرابط غير صالح. استخدم رابط HTTP أو HTTPS.');
    }
    return u.toString();
  }

  Future<void> inspect([String? raw]) async {
    final input = raw ?? urlCtrl.text;
    if (input.trim().isEmpty) return;
    setState(() { inspecting = true; error = ''; status = 'جارٍ فحص الرابط…'; info = null; });
    try {
      final url = _cleanUrl(input);
      Response<dynamic> res;
      try {
        res = await dio.head(url, options: Options(responseType: ResponseType.plain, validateStatus: (s) => s != null && s < 500));
      } catch (_) {
        res = await dio.get(url, options: Options(
          responseType: ResponseType.stream,
          headers: {'Range': 'bytes=0-0'},
          validateStatus: (s) => s != null && s < 500,
        ));
      }
      final headers = res.headers;
      final mime = headers.value(Headers.contentTypeHeader)?.split(';').first;
      final lengthText = headers.value(Headers.contentLengthHeader);
      final length = int.tryParse(lengthText ?? '');
      final kind = kindFrom(mime, url);
      final disposition = headers.value('content-disposition') ?? '';
      final nameMatch = RegExp(r'filename="?([^";]+)').firstMatch(disposition);
      final fallback = Uri.parse(url).pathSegments.isNotEmpty ? Uri.parse(url).pathSegments.last : 'download';
      final filename = nameMatch?.group(1) ?? (fallback.isEmpty ? 'download' : fallback);
      info = LinkInfo(url, mime ?? 'غير معروف', filename, length, kind);
      status = kind == MediaKind.page
        ? 'تم الوصول إلى صفحة ويب؛ لا يوجد ملف مباشر مؤكد.'
        : (kind == MediaKind.other ? 'تم الفحص؛ نوع الملف غير محسوم.' : 'تم التعرف على ${info!.label}.');
    } catch (e) {
      error = e.toString(); status = 'تعذر فحص الرابط';
    } finally {
      if (mounted) setState(() => inspecting = false);
    }
  }

  Future<void> pasteAndInspect() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) { _toast('الحافظة فارغة'); return; }
    urlCtrl.text = text;
    await inspect(text);
  }

  Future<Directory> _targetDir(MediaKind kind) async {
    if (kind == MediaKind.video || kind == MediaKind.image) {
      final dir = await getTemporaryDirectory();
      return Directory('${dir.path}/jesi_media')..createSync(recursive: true);
    }
    final base = await getExternalStorageDirectory();
    final dir = Directory('${base?.path ?? (await getApplicationDocumentsDirectory()).path}/JESI');
    await dir.create(recursive: true);
    return dir;
  }

  Future<void> download() async {
    final item = info;
    if (item == null) return;
    if (item.kind == MediaKind.page || item.kind == MediaKind.other) {
      _toast('هذا الرابط ليس ملف وسائط مباشراً قابلاً للتنزيل.');
      return;
    }
    if (downloading) return;
    if (Platform.isAndroid) {
      await Permission.notification.request();
      if (item.kind == MediaKind.image || item.kind == MediaKind.video) {
        await Permission.photos.request();
        await Permission.videos.request();
      }
    }
    setState(() { downloading = true; progress = 0; status = 'جارٍ التحميل…'; error = ''; });
    await _performDownload(item);
  }

  Future<void> _performDownload(LinkInfo item) async {
    final token = CancelToken(); cancel = token;
    try {
      final dir = await _targetDir(item.kind);
      var filename = item.name.replaceAll(RegExp(r'[\\\\/:*?"<>|]'), '_');
      if (!filename.contains('.')) {
        filename += item.kind == MediaKind.video ? '.mp4' : item.kind == MediaKind.image ? '.jpg' : '.mp3';
      }
      final path = '${dir.path}/$filename';
      final sw = Stopwatch()..start();
      var lastBytes = 0, lastTime = 0;
      await dio.download(item.url, path, cancelToken: token,
        options: Options(followRedirects: true, receiveTimeout: const Duration(minutes: 10)),
        onReceiveProgress: (received, total) async {
          if (!mounted) return;
          final now = sw.elapsedMilliseconds;
          final delta = received - lastBytes;
          final dt = max(1, now - lastTime);
          if (dt >= 500) { speed = '${(delta * 1000 / dt / 1024).toStringAsFixed(1)} KB/s'; lastBytes = received; lastTime = now; }
          setState(() { if (total > 0) progress = received / total; });
          await Notice.show('JESI Downloader', 'تحميل ${(progress * 100).toStringAsFixed(0)}%', id: 7);
        });
      if (item.kind == MediaKind.video || item.kind == MediaKind.image) {
        if (item.kind == MediaKind.video) { await Gal.putVideo(path); } else { await Gal.putImage(path); }
      }
      setState(() { downloading = false; progress = 1; status = 'اكتمل التحميل'; speed = 'مكتمل'; });
      await Notice.done('اكتمل التحميل', filename, id: 7);
      _toast('اكتمل: $filename');
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        setState(() { downloading = false; status = 'تم إيقاف التحميل'; });
      } else {
        setState(() { status = online ? 'انقطع التحميل؛ ستتم إعادة المحاولة' : 'بانتظار عودة الإنترنت…'; error = e.message ?? 'Network error'; });
        await Notice.done('JESI: إعادة المحاولة', status, id: 7);
        _retryIfNeeded();
      }
    } catch (e) {
      setState(() { downloading = false; status = 'تعذر حفظ الملف'; error = e.toString(); });
      await Notice.done('JESI: فشل التحميل', 'تحقق من صلاحيات التخزين والرابط', id: 7);
    }
  }

  void _retryIfNeeded() {
    retryTimer?.cancel();
    if (!downloading) return;
    retryTimer = Timer(const Duration(seconds: 5), () async {
      if (!mounted || !downloading || info == null) return;
      if (!online) { _retryIfNeeded(); return; }
      await _performDownload(info!);
    });
  }

  Future<void> stopDownload() async {
    cancel?.cancel('Stopped by user');
    retryTimer?.cancel();
    if (mounted) setState(() => downloading = false);
    await Notice.done('JESI Downloader', 'تم إيقاف التحميل', id: 7);
  }

  void _toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> openSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsPage(prefs: prefs, secure: secure)));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Row(children: [Icon(Icons.downloading_rounded, color: neon), SizedBox(width: 8), Text('JESI', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 2))]),
      actions: [IconButton(onPressed: openSettings, icon: const Icon(Icons.tune_rounded)), const SizedBox(width: 8)],
    ),
    body: SafeArea(child: ListView(padding: const EdgeInsets.all(18), children: [
      const SizedBox(height: 10),
      AnimatedBuilder(animation: pulse, builder: (_, __) => Center(
        child: Container(width: 154, height: 154,
          decoration: BoxDecoration(shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: neon.withOpacity(.12 + pulse.value * .18), blurRadius: 32, spreadRadius: 8)],
            border: Border.all(color: neon.withOpacity(.5 + pulse.value * .4), width: 1.5),
            gradient: const RadialGradient(colors: [Color(0xFF183A3B), Color(0xFF0B141C)])),
          child: const Icon(Icons.download_rounded, size: 72, color: neon)),
      )),
      const SizedBox(height: 20),
      const Center(child: Text('حمّل بذكاء مع الجيسي', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold))),
      const SizedBox(height: 6),
      Center(child: Text('فحص الروابط والملفات المباشرة', style: TextStyle(color: Colors.white.withOpacity(.55)))),
      const SizedBox(height: 24),
      TextField(controller: urlCtrl, keyboardType: TextInputType.url, decoration: InputDecoration(
        hintText: 'ألصق رابط الفيديو أو الصورة هنا',
        prefixIcon: const Icon(Icons.link, color: neon),
        suffixIcon: IconButton(icon: const Icon(Icons.content_paste, color: neon), onPressed: pasteAndInspect))),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: FilledButton.icon(onPressed: inspecting ? null : () => inspect(), icon: inspecting ? const SizedBox(width: 18,height:18,child:CircularProgressIndicator(strokeWidth:2)) : const Icon(Icons.search), label: const Text('افحص الرابط'))),
        const SizedBox(width: 10),
        IconButton.filledTonal(onPressed: pasteAndInspect, icon: const Icon(Icons.my_location), tooltip: 'فحص آخر رابط منسوخ'),
      ]),
      const SizedBox(height: 16),
      _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [const Icon(Icons.radar, color: neon), const SizedBox(width: 8), const Text('نتيجة الفحص', style: TextStyle(fontWeight: FontWeight.bold)), const Spacer(), _pill(online ? 'متصل' : 'غير متصل', online ? neon : Colors.orange)]),
        const SizedBox(height: 12),
        Text(status, style: const TextStyle(fontSize: 15)),
        if (info != null) ...[
          const Divider(height: 22),
          _detail('النوع', info!.label),
          _detail('MIME', info!.type),
          _detail('الاسم', info!.name),
          _detail('الحجم', info!.length == null ? 'غير معروف' : '${(info!.length! / 1024 / 1024).toStringAsFixed(2)} MB'),
          if (info!.kind == MediaKind.page) const Text('هذا رابط صفحة وليس رابط ملف مباشر.'),
        ],
        if (error.isNotEmpty) Text(error, style: const TextStyle(color: Colors.orangeAccent, fontSize: 12)),
      ])),
      const SizedBox(height: 14),
      if (info != null && [MediaKind.video, MediaKind.image, MediaKind.audio].contains(info!.kind))
        FilledButton.icon(onPressed: downloading ? null : download, icon: const Icon(Icons.download), label: const Text('تنزيل الملف')),
      if (downloading) ...[
        const SizedBox(height: 12),
        _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [const Text('تقدم التحميل', style: TextStyle(fontWeight: FontWeight.bold)), const Spacer(), Text('${(progress*100).toStringAsFixed(0)}%')]),
          const SizedBox(height: 10),
          LinearProgressIndicator(value: progress == 0 ? null : progress, minHeight: 7, borderRadius: BorderRadius.circular(9), color: neon, backgroundColor: Colors.white12),
          const SizedBox(height: 8),
          Row(children: [Text('السرعة: $speed', style: const TextStyle(color: neon)), const Spacer(), Text(online ? 'الاتصال متاح' : 'بانتظار الشبكة', style: const TextStyle(color: Colors.orange))]),
          Align(alignment: Alignment.centerRight, child: TextButton.icon(onPressed: stopDownload, icon: const Icon(Icons.stop), label: const Text('إيقاف'))),
        ])),
      ],
      const SizedBox(height: 14),
      _panel(child: Row(children: [
        const Icon(Icons.auto_awesome, color: neon), const SizedBox(width: 10),
        const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('مساعد تحليل الروابط', style: TextStyle(fontWeight: FontWeight.bold)), Text('اسأل النموذج عن الرابط بعد ضبط API', style: TextStyle(fontSize: 12, color: Colors.white54))])),
        TextButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AssistantPage(secure: secure))), child: const Text('فتح')),
      ])),
      const SizedBox(height: 22),
      const Center(child: Text('JESI DOWNLOADER • NO ADS', style: TextStyle(color: Colors.white30, fontSize: 10, letterSpacing: 1.5))),
    ])),
  );

  Widget _panel({required Widget child}) => Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: const Color(0xFF101820), borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.white.withOpacity(.07))), child: child);
  Widget _pill(String t, Color c) => Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5), decoration: BoxDecoration(color: c.withOpacity(.12), borderRadius: BorderRadius.circular(20)), child: Text(t, style: TextStyle(color: c, fontSize: 11)));
  Widget _detail(String a, String b) => Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(children: [Text(a, style: const TextStyle(color: Colors.white54)), const Spacer(), Flexible(child: Text(b, textAlign: TextAlign.end))]));
}

class SettingsPage extends StatefulWidget {
  final SharedPreferences prefs;
  final FlutterSecureStorage secure;
  const SettingsPage({super.key, required this.prefs, required this.secure});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}
class _SettingsPageState extends State<SettingsPage> {
  final model = TextEditingController(), endpoint = TextEditingController(), keyCtrl = TextEditingController();
  bool saved = false, showKey = false;
  @override
  void initState() { super.initState(); model.text = widget.prefs.getString('model') ?? 'gpt-4o-mini'; endpoint.text = widget.prefs.getString('endpoint') ?? 'https://api.openai.com/v1/chat/completions'; widget.secure.read(key: 'api_key').then((v) { if (mounted) keyCtrl.text = v ?? ''; }); }
  @override
  void dispose() { model.dispose(); endpoint.dispose(); keyCtrl.dispose(); super.dispose(); }
  Future<void> save() async {
    await widget.prefs.setString('model', model.text.trim());
    await widget.prefs.setString('endpoint', endpoint.text.trim());
    await widget.secure.write(key: 'api_key', value: keyCtrl.text.trim());
    if (mounted) setState(() => saved = true);
  }
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('الإعدادات والنموذج')), body: ListView(padding: const EdgeInsets.all(18), children: [
    const Text('إعدادات المساعد الذكي', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
    const SizedBox(height: 16),
    TextField(controller: model, decoration: const InputDecoration(labelText: 'اسم النموذج')),
    const SizedBox(height: 12),
    TextField(controller: endpoint, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'رابط API endpoint')),
    const SizedBox(height: 12),
    TextField(controller: keyCtrl, obscureText: !showKey, decoration: InputDecoration(labelText: 'مفتاح API', suffixIcon: IconButton(onPressed: () => setState(() => showKey = !showKey), icon: Icon(showKey ? Icons.visibility_off : Icons.visibility)))),
    const SizedBox(height: 16),
    FilledButton.icon(onPressed: save, icon: const Icon(Icons.save), label: const Text('حفظ الإعدادات')),
    if (saved) const Padding(padding: EdgeInsets.only(top: 10), child: Text('تم حفظ الإعدادات على الجهاز.', style: TextStyle(color: neon))),
    const SizedBox(height: 18),
    const Text('المفتاح محفوظ محلياً بتخزين آمن على Android. استخدم مزود API موثوقاً؛ لا تشارك المفتاح مع أحد.', style: TextStyle(color: Colors.white54)),
  ]));
}

class AssistantPage extends StatefulWidget {
  final FlutterSecureStorage secure;
  const AssistantPage({super.key, required this.secure});
  @override
  State<AssistantPage> createState() => _AssistantPageState();
}
class _AssistantPageState extends State<AssistantPage> {
  final url = TextEditingController(), question = TextEditingController();
  String answer = '';
  bool busy = false;
  Future<void> ask() async {
    if (url.text.trim().isEmpty || question.text.trim().isEmpty) return;
    setState(() { busy = true; answer = ''; });
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = await widget.secure.read(key: 'api_key') ?? '';
      final endpoint = prefs.getString('endpoint') ?? '';
      final model = prefs.getString('model') ?? 'gpt-4o-mini';
      if (key.isEmpty || endpoint.isEmpty) throw Exception('أدخل endpoint ومفتاح API من الإعدادات أولاً.');
      final response = await Dio().post(endpoint,
        options: Options(headers: {'Authorization': 'Bearer $key', 'Content-Type': 'application/json'}),
        data: {'model': model, 'messages': [
          {'role': 'system', 'content': 'حلل الروابط بحذر. لا تدّعِ أن الرابط آمن بشكل مؤكد. وضح مؤشرات الخطر وحدود الفحص، ولا تفتح الرابط أو تنفذ محتواه.'},
          {'role': 'user', 'content': 'الرابط: ${url.text}\nالسؤال: ${question.text}\nأعطني تقييماً أولياً وتفاصيل يمكن استنتاجها دون فتح محتوى ضار.'}
        ]});
      answer = response.data['choices']?[0]?['message']?['content']?.toString() ?? 'لم يصل رد مفهوم من النموذج.';
    } catch (e) { answer = 'تعذر إكمال الطلب: $e'; }
    finally { if (mounted) setState(() => busy = false); }
  }
  @override
  void dispose() { url.dispose(); question.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('مساعد الجيسي')), body: ListView(padding: const EdgeInsets.all(18), children: [
    TextField(controller: url, decoration: const InputDecoration(labelText: 'الرابط المراد تحليله', prefixIcon: Icon(Icons.link))),
    const SizedBox(height: 12),
    TextField(controller: question, maxLines: 3, decoration: const InputDecoration(labelText: 'ماذا تريد أن تعرف عن الرابط؟')),
    const SizedBox(height: 12),
    FilledButton.icon(onPressed: busy ? null : ask, icon: const Icon(Icons.auto_awesome), label: Text(busy ? 'جارٍ التحليل…' : 'اسأل النموذج')),
    if (busy) const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
    if (answer.isNotEmpty) Container(margin: const EdgeInsets.only(top: 18), padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: const Color(0xFF101820), borderRadius: BorderRadius.circular(18)), child: SelectableText(answer)),
  ]));
}
