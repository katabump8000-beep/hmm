import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const neon = Color(0xFF20E6C5), bg = Color(0xFF070B10);
Future<void> main() async { WidgetsFlutterBinding.ensureInitialized(); await Notice.init(); runApp(const JesiApp()); }

class Notice {
  static final p = FlutterLocalNotificationsPlugin();
  static Future<void> init() async {
    await p.initialize(const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')));
    await p.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
  }
  static Future<void> progress(int n, String s) async => p.show(7,'JESI • تنزيل',s,NotificationDetails(android:AndroidNotificationDetails('jesi_downloads','JESI downloads',importance:Importance.low,priority:Priority.low,ongoing:true,onlyAlertOnce:true,showProgress:true,maxProgress:100,progress:n.clamp(0,100))));
  static Future<void> done(String t,String s) async => p.show(7,t,s,const NotificationDetails(android:AndroidNotificationDetails('jesi_downloads','JESI downloads')));
}

class JesiApp extends StatelessWidget {
 const JesiApp({super.key});
 @override Widget build(BuildContext c)=>MaterialApp(debugShowCheckedModeBanner:false,title:'JESI Downloader',theme:ThemeData(brightness:Brightness.dark,scaffoldBackgroundColor:bg,colorScheme:const ColorScheme.dark(primary:neon,secondary:Color(0xFF687BFF)),useMaterial3:true),home:const Home());
}
enum Kind { video,image,audio,page,other }
Kind detect(String mime,String url) {
 final m=mime.toLowerCase(), p=Uri.tryParse(url)?.path.toLowerCase()??'';
 if(m.startsWith('video/')||['.mp4','.mov','.m4v','.webm','.mkv'].any(p.endsWith)) return Kind.video;
 if(m.startsWith('image/')||['.jpg','.jpeg','.png','.webp','.gif'].any(p.endsWith)) return Kind.image;
 if(m.startsWith('audio/')||['.mp3','.m4a','.aac','.wav','.ogg','.flac'].any(p.endsWith)) return Kind.audio;
 if(m.contains('html')||m.isEmpty) return Kind.page;
 return Kind.other;
}
String sizeText(int n)=>'${(n/1048576).toStringAsFixed(2)} MB';
String clean(String s)=>s.replaceAll(RegExp(r'[\\/:*?"<>|]'),'_');

class Home extends StatefulWidget { const Home({super.key}); @override State<Home> createState()=>_HomeState(); }
class _HomeState extends State<Home> with TickerProviderStateMixin {
 final url=TextEditingController(), secure=const FlutterSecureStorage();
 final dio=Dio(BaseOptions(connectTimeout:const Duration(seconds:25),receiveTimeout:const Duration(minutes:20),followRedirects:true,maxRedirects:10));
 Link? link; bool checking=false,downloading=false,online=true; double pct=0;
 int got=0,total=0,count=0; String status='ألصق رابط ملف مباشر للفحص',speed='—',err='';
 CancelToken? token; StreamSubscription<List<ConnectivityResult>>? net;
 late AnimationController anim;
 @override void initState(){super.initState();anim=AnimationController(vsync:this,duration:const Duration(seconds:2))..repeat(reverse:true);net=Connectivity().onConnectivityChanged.listen((v){if(mounted)setState(()=>online=!v.contains(ConnectivityResult.none));}); SharedPreferences.getInstance().then((p){if(mounted)setState(()=>count=p.getInt('done')??0);});}
 @override void dispose(){url.dispose();anim.dispose();net?.cancel();token?.cancel();super.dispose();}
 void toast(String s)=>ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(s)));
 String normalize(String raw){final u=Uri.tryParse(raw.trim().contains('://')?raw.trim():'https://${raw.trim()}');if(u==null||!u.hasAuthority||!['http','https'].contains(u.scheme))throw const FormatException('الرابط غير صالح');return u.toString();}
 Future<void> inspect() async {
  if(url.text.trim().isEmpty)return; setState(() {
    checking = true;
    err = '';
    link = null;
    status = 'جارٍ فحص الرابط…';
   });
  try{
   final u=normalize(url.text); Response r;
   try{r=await dio.head(u,options:Options(validateStatus:(s)=>s!=null&&s<500));}
   catch(_){r=await dio.get(u,options:Options(responseType:ResponseType.stream,headers:{'Range':'bytes=0-0'},validateStatus:(s)=>s!=null&&s<500));}
   if(r.statusCode==405||r.statusCode==501)r=await dio.get(u,options:Options(responseType:ResponseType.stream,headers:{'Range':'bytes=0-0'},validateStatus:(s)=>s!=null&&s<500));
   if((r.statusCode??500)>=400)throw Exception('المصدر رفض الطلب: HTTP ${r.statusCode}');
   final mime=r.headers.value('content-type')?.split(';').first??'';
   final len=int.tryParse(r.headers.value('content-length')??r.headers.value('content-range')?.split('/').last??'')??0;
   final k=detect(mime,u), parts=Uri.parse(u).pathSegments;
   final cd=r.headers.value('content-disposition')??'';
   final fn=RegExp(r'filename="?([^";]+)').firstMatch(cd)?.group(1)??(parts.isEmpty?'download':parts.last);
   link=Link(u,mime,Uri.decodeComponent(fn),len,k);
   status=k==Kind.page?'وصلنا لصفحة ويب، وليس لملف وسائط مباشر.':'تم العثور على ملف ${k.name} مباشر.';
  }catch(e){err=errText(e);status='تعذر فحص الرابط';}
  finally{if(mounted)setState(()=>checking=false);}
 }
 String errText(Object e){if(e is DioException){final c=e.response?.statusCode;if(c==401||c==403)return 'رفض الموقع الوصول (HTTP $c). قد يحتاج الرابط لصلاحية.';if(c==404)return 'الملف غير موجود (404).';if(e.type==DioExceptionType.connectionTimeout)return 'انتهت مهلة الاتصال.';return e.message??'خطأ اتصال';}return e.toString();}
 Future<Directory> folder()async{final d=Directory('${(await getApplicationDocumentsDirectory()).path}/JESI_Downloads');await d.create(recursive:true);return d;}
 Future<void> download() async {
  final x=link;if(x==null)return;if(x.kind==Kind.page||x.kind==Kind.other){toast('هذا رابط صفحة وليس ملفاً مباشراً.');return;}
  setState(() {
    downloading = true;
    pct = 0;
    got = 0;
    total = x.length;
    speed = 'حساب السرعة…';
    err = '';
    status = 'جارٍ التنزيل…';
   });
  token=CancelToken();final sw=Stopwatch()..start();int old=0,oldMs=0;
  try{
   final d=await folder();var name=clean(x.name);if(!name.contains('.'))name+=x.kind==Kind.video?'.mp4':x.kind==Kind.image?'.jpg':'.mp3';
   var path='${d.path}/$name';if(await File(path).exists())path='${d.path}/${DateTime.now().millisecondsSinceEpoch}_$name';
   await dio.download(x.url,path,cancelToken:token,options:Options(headers:{'Accept-Encoding':'identity'},receiveTimeout:const Duration(minutes:20)),onReceiveProgress:(r,t){
    if(!mounted)return;final ms=sw.elapsedMilliseconds;if(ms-oldMs>400){final kb=max(0,r-old)*1000/max(1,ms-oldMs)/1024;speed=kb>1024?'${(kb/1024).toStringAsFixed(2)} MB/s':'${kb.toStringAsFixed(0)} KB/s';old=r;oldMs=ms;}
    setState(() {
      got = r;
      if (t > 0) total = t;
      pct = total > 0 ? (r / total).clamp(0, 1) : 0;
      status = 'جارٍ تنزيل $name';
     });
    Notice.progress((pct*100).round(),'${sizeText(got)} / ${sizeText(total)}');
   });
   if(await File(path).length()==0)throw Exception('الملف فارغ');
   final p=await SharedPreferences.getInstance();count=(p.getInt('done')??0)+1;await p.setInt('done',count);
   if (!mounted) return;
   setState(() {
    downloading = false;
    pct = 1;
    status = 'اكتمل التنزيل';
    speed = 'مكتمل';
   });
   await Notice.done('اكتمل التنزيل', name);
   if (!mounted) return;
   toast('حُفظ في مكتبة JESI');
  } catch (e) {
   if (!mounted) return;
   setState(() {
    downloading = false;
    status = 'فشل التنزيل';
    err = e is DioException ? errText(e) : e.toString();
    speed = '—';
   });
   await Notice.done('فشل التنزيل', err);
  }
 }
 Future<void> paste()async{final s=(await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim()??'';if(s.isEmpty){toast('الحافظة فارغة');return;}url.text=s;await inspect();}
 @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('⬇ JESI',style:TextStyle(fontWeight:FontWeight.w900,letterSpacing:2)),actions:[IconButton(onPressed:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>Assistant(secure:secure))),icon:const Icon(Icons.auto_awesome)),IconButton(onPressed:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>Settings(secure:secure))),icon:const Icon(Icons.tune))]),body:SafeArea(child:ListView(padding:const EdgeInsets.all(18),children:[
  Center(child:AnimatedBuilder(animation:anim,builder:(_,__)=>Container(width:145,height:145,decoration:BoxDecoration(shape:BoxShape.circle,border:Border.all(color:neon.withValues(alpha: .5+anim.value*.4),width:2),boxShadow:[BoxShadow(color:neon.withValues(alpha: .18),blurRadius:30,spreadRadius:8)]),child:const Icon(Icons.download,size:72,color:neon)))),
  const SizedBox(height:20),const Center(child:Text('حمّل بذكاء مع الجيسي',style:TextStyle(fontSize:22,fontWeight:FontWeight.bold))),
  const SizedBox(height:20),TextField(controller:url,keyboardType:TextInputType.url,decoration:InputDecoration(hintText:'رابط ملف فيديو أو صورة أو صوت',prefixIcon:const Icon(Icons.link,color:neon),suffixIcon:IconButton(onPressed:paste,icon:const Icon(Icons.content_paste,color:neon)))),
  const SizedBox(height:12),FilledButton.icon(onPressed:checking?null:inspect,icon:checking?const SizedBox(width:18,height:18,child:CircularProgressIndicator(strokeWidth:2)):const Icon(Icons.search),label:const Text('افحص الرابط')),
  const SizedBox(height:14),_panel(Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
   Row(children:[const Icon(Icons.radar,color:neon),const SizedBox(width:8),const Text('نتيجة الفحص',style:TextStyle(fontWeight:FontWeight.bold)),const Spacer(),Text(online?'متصل':'غير متصل',style:TextStyle(color:online?neon:Colors.orange))]),
   const SizedBox(height:10),Text(status),
   if(link!=null)...[const Divider(),_line('النوع',link!.kind.name),_line('MIME',link!.mime),_line('الاسم',link!.name),_line('الحجم',sizeText(link!.length))],
   if(err.isNotEmpty)Text(err,style:const TextStyle(color:Colors.orangeAccent))
  ])),
  if(link!=null&&[Kind.video,Kind.audio,Kind.image].contains(link!.kind))...[
   const SizedBox(height:12),_panel(Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
    const Text('خيارات التنزيل',style:TextStyle(fontWeight:FontWeight.bold)),
    Text(link!.kind==Kind.video?'الدقة المتاحة: الملف الأصلي الذي يقدمه الرابط. لا يمكن إنشاء 144p أو 1080p إن لم يوفرها المصدر.':link!.kind==Kind.audio?'الصيغة والجودة الأصلية التي يوفرها الرابط.':'جودة الصورة الأصلية.',style:const TextStyle(color:Colors.white60)),
    const SizedBox(height:10),SizedBox(width:double.infinity,child:FilledButton.icon(onPressed:downloading?null:download,icon:const Icon(Icons.download),label:const Text('تنزيل الملف')))
   ]))
  ],
  if(downloading||got>0)...[const SizedBox(height:12),_panel(Column(children:[
   Row(children:[const Text('مؤشر التنزيل'),const Spacer(),Text('${(pct*100).round()}%')]),const SizedBox(height:8),LinearProgressIndicator(value:total>0?pct:null,color:neon,minHeight:7),
   _line('السرعة',speed),_line('تم تنزيل',sizeText(got)),_line('الحجم الإجمالي',sizeText(total)),_line('عدد التنزيلات المكتملة','$count'),
   if(downloading)TextButton(onPressed:()=>token?.cancel('إيقاف من المستخدم'),child:const Text('إيقاف التنزيل'))
  ]))],
  const SizedBox(height:14),_panel(Row(children:[const Icon(Icons.folder_copy,color:neon,size:28),const SizedBox(width:12),const Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('التنزيلات',style:TextStyle(fontWeight:FontWeight.bold)),Text('فيديوهات • أغاني • صور',style:TextStyle(color:Colors.white54,fontSize:12))])),TextButton(onPressed:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>const Library())),child:const Text('فتح'))])),
  const SizedBox(height:20),const Center(child:Text('JESI DOWNLOADER • NO ADS',style:TextStyle(color:Colors.white30,fontSize:10)))
 ])));
 Widget _panel(Widget w)=>Container(padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:const Color(0xFF101820),borderRadius:BorderRadius.circular(18),border:Border.all(color:Colors.white12)),child:w);
 Widget _line(String a,String b)=>Padding(padding:const EdgeInsets.symmetric(vertical:4),child:Row(children:[Text(a,style:const TextStyle(color:Colors.white54)),const Spacer(),Flexible(child:Text(b,textAlign:TextAlign.end))]));
}
class Link{final String url,mime,name;final int length;final Kind kind;Link(this.url,this.mime,this.name,this.length,this.kind);}

class Library extends StatefulWidget{const Library({super.key});@override State<Library> createState()=>_LibraryState();}
class _LibraryState extends State<Library>{
 final player=AudioPlayer();List<File> files=[];int tab=0;String? playing;
 @override void initState(){super.initState();load();}
 @override void dispose(){player.dispose();super.dispose();}
 Future<void> load()async{final d=Directory('${(await getApplicationDocumentsDirectory()).path}/JESI_Downloads');if(await d.exists())files=d.listSync().whereType<File>().toList()..sort((a,b)=>b.lastModifiedSync().compareTo(a.lastModifiedSync()));if(mounted)setState((){});}
 Kind kind(File f)=>detect('',f.path);
 List<File> get shown=>files.where((f){final k=kind(f);return tab==0||(tab==1&&k==Kind.video)||(tab==2&&k==Kind.audio)||(tab==3&&k==Kind.image);}).toList();
 Future<void> play(File f)async{try{if(playing==f.path&&player.playing){await player.pause();}else{await player.setFilePath(f.path);playing=f.path;await player.play();}
   if (!mounted) return;
   setState(() {});
  } catch (e) {
   if (!mounted) return;
   ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('تعذر تشغيل الصوت: $e')),
   );
  }}
 @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('التنزيلات')),body:Column(children:[
  Padding(padding:const EdgeInsets.all(10),child:Wrap(spacing:6,children:List.generate(4,(i)=>ChoiceChip(label:Text(['الكل','الفيديوهات','الأغاني','الصور'][i]),selected:tab==i,onSelected:(_)=>setState(()=>tab=i),selectedColor:neon.withValues(alpha: .2))))),
  Expanded(child:shown.isEmpty?const Center(child:Text('لا توجد ملفات محفوظة في هذا القسم.')):RefreshIndicator(onRefresh:load,child:ListView.builder(itemCount:shown.length,itemBuilder:(_,i){
   final f=shown[i],k=kind(shown[i]);final icon=k==Kind.audio?Icons.music_note:k==Kind.video?Icons.movie:Icons.image;
   return Card(color:const Color(0xFF101820),child:ListTile(leading:k==Kind.image?ClipRRect(borderRadius:BorderRadius.circular(8),child:Image.file(f,width:52,height:52,fit:BoxFit.cover,errorBuilder:(_,__,___)=>const Icon(Icons.image,color:neon))):CircleAvatar(child:Icon(icon,color:neon)),
    title:Text(f.uri.pathSegments.last,maxLines:1,overflow:TextOverflow.ellipsis),subtitle:Text(sizeText(f.lengthSync())),
    trailing:k==Kind.audio?IconButton(onPressed:()=>play(f),icon:Icon(playing==f.path&&player.playing?Icons.pause_circle:Icons.play_circle,color:neon,size:30)):const Icon(Icons.check_circle,color:neon),
    onTap:k==Kind.audio?()=>play(f):k==Kind.image?()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>ImageView(file:f))):k==Kind.video?()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>VideoView(file:f))):null));
  }))),
  if(playing!=null)Padding(padding:const EdgeInsets.all(10),child:Row(children:[const Icon(Icons.graphic_eq,color:neon),Expanded(child:Text(playing!.split('/').last,maxLines:1,overflow:TextOverflow.ellipsis)),IconButton(onPressed:()=>player.playing?player.pause():player.play(),icon:Icon(player.playing?Icons.pause:Icons.play_arrow,color:neon))]))
 ]));
}


class Assistant extends StatefulWidget {
 final FlutterSecureStorage secure;
 const Assistant({super.key,required this.secure});
 @override State<Assistant> createState()=>_AssistantState();
}
class _AssistantState extends State<Assistant> {
 final url=TextEditingController(),question=TextEditingController();
 String answer='';bool busy=false;
 Future<void> ask() async {
  if(url.text.trim().isEmpty||question.text.trim().isEmpty)return;
  setState(() {
    busy = true;
    answer = '';
   });
  try{
   final p=await SharedPreferences.getInstance();
   final key=(await widget.secure.read(key:'api_key')??'').trim();
   final endpoint=(p.getString('endpoint')??'https://api.openai.com/v1/chat/completions').trim();
   final model=(p.getString('model')??'gpt-4o-mini').trim();
   if(key.isEmpty)throw Exception('أضف مفتاح OpenAI من الإعدادات أولاً.');
   final r=await Dio().post(endpoint,
    options:Options(headers:{'Authorization':'Bearer $key','Content-Type':'application/json'},validateStatus:(v)=>v!=null&&v<500),
    data:{'model':model,'messages':[
     {'role':'system','content':'أنت مساعد لتحليل روابط الوسائط. لا تدّعِ استخراج ملف لم يتم التحقق منه.'},
     {'role':'user','content':'الرابط: ${url.text}\\nالسؤال: ${question.text}'}
    ]});
   if(r.statusCode==401)throw Exception('OpenAI رفض المفتاح (401). تحقق من صحته وأنه غير ملغى.');
   if(r.statusCode==403)throw Exception('لا توجد صلاحية كافية للمفتاح أو المشروع (403).');
   if(r.statusCode==404)throw Exception('النموذج أو عنوان API غير موجود (404).');
   if(r.statusCode==429)throw Exception('تم بلوغ حد الاستخدام أو الرصيد (429).');
   if((r.statusCode??500)>=400)throw Exception('HTTP ${r.statusCode}: ${r.data}');
   answer=r.data['choices']?[0]?['message']?['content']?.toString()??'لم يصل رد مفهوم.';
  }catch(e){answer='تعذر إكمال الطلب: $e';}
  finally{if(mounted)setState(()=>busy=false);}
 }
 @override void dispose(){url.dispose();question.dispose();super.dispose();}
 @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('مساعد OpenAI')),body:ListView(padding:const EdgeInsets.all(18),children:[
  TextField(controller:url,decoration:const InputDecoration(labelText:'الرابط')),
  const SizedBox(height:12),TextField(controller:question,maxLines:3,decoration:const InputDecoration(labelText:'ما الذي تريد تحليله؟')),
  const SizedBox(height:12),FilledButton.icon(onPressed:busy?null:ask,icon:const Icon(Icons.auto_awesome),label:Text(busy?'جارٍ التحليل…':'اسأل OpenAI')),
  if(busy)const Padding(padding:EdgeInsets.all(12),child:LinearProgressIndicator()),
  if(answer.isNotEmpty)Container(margin:const EdgeInsets.only(top:16),padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:const Color(0xFF101820),borderRadius:BorderRadius.circular(16)),child:SelectableText(answer))
 ]));
}


class ImageView extends StatelessWidget {
 final File file; const ImageView({super.key,required this.file});
 @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:Text(file.uri.pathSegments.last)),body:Center(child:InteractiveViewer(child:Image.file(file,fit:BoxFit.contain))));
}
class VideoView extends StatefulWidget {
 final File file; const VideoView({super.key,required this.file});
 @override State<VideoView> createState()=>_VideoViewState();
}
class _VideoViewState extends State<VideoView> {
 late final VideoPlayerController controller;
 @override void initState(){super.initState();controller=VideoPlayerController.file(widget.file)..initialize().then((_){if(mounted)setState((){});});}
 @override void dispose(){controller.dispose();super.dispose();}
 @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:Text(widget.file.uri.pathSegments.last)),body:Center(child:controller.value.isInitialized?AspectRatio(aspectRatio:controller.value.aspectRatio,child:Stack(alignment:Alignment.bottomCenter,children:[
  VideoPlayer(controller),VideoProgressIndicator(controller,allowScrubbing:true,padding:const EdgeInsets.all(12)),
  Align(alignment:Alignment.center,child:IconButton(iconSize:64,color:Colors.white,onPressed:(){if(controller.value.isPlaying){controller.pause();}else{controller.play();}setState((){});},icon:Icon(controller.value.isPlaying?Icons.pause_circle:Icons.play_circle)))
 ])):const CircularProgressIndicator()));
}

class Settings extends StatefulWidget{final FlutterSecureStorage secure;const Settings({super.key,required this.secure});@override State<Settings> createState()=>_SettingsState();}
class _SettingsState extends State<Settings>{
 final model=TextEditingController(text:'gpt-4o-mini'),endpoint=TextEditingController(text:'https://api.openai.com/v1/chat/completions'),key=TextEditingController();bool show=false;
 @override void initState(){super.initState();SharedPreferences.getInstance().then((p){model.text=p.getString('model')??model.text;endpoint.text=p.getString('endpoint')??endpoint.text;});widget.secure.read(key:'api_key').then((v){if(mounted)key.text=v??'';});}
 @override void dispose(){model.dispose();endpoint.dispose();key.dispose();super.dispose();}
 Future<void> save()async{final p=await SharedPreferences.getInstance();await p.setString('model',model.text.trim());await p.setString('endpoint',endpoint.text.trim());await widget.secure.write(key:'api_key',value:key.text.trim());if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('تم حفظ إعدادات OpenAI')));}
 @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('إعدادات OpenAI')),body:ListView(padding:const EdgeInsets.all(18),children:[
  TextField(controller:model,decoration:const InputDecoration(labelText:'اسم النموذج')),
  const SizedBox(height:12),TextField(controller:endpoint,decoration:const InputDecoration(labelText:'API endpoint')),
  const SizedBox(height:12),TextField(controller:key,obscureText:!show,decoration:InputDecoration(labelText:'مفتاح OpenAI API',suffixIcon:IconButton(onPressed:()=>setState(()=>show=!show),icon:Icon(show?Icons.visibility_off:Icons.visibility)))),
  const SizedBox(height:16),FilledButton(onPressed:save,child:const Text('حفظ')),
  const SizedBox(height:12),const Text('استخدم مفتاحاً صالحاً ونموذجاً متاحاً. خطأ 401 يعني أن OpenAI رفض بيانات المصادقة.',style:TextStyle(color:Colors.white60))
 ]));
}
