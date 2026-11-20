package com.jesi.jesi_downloader

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import androidx.core.app.NotificationCompat
import com.yausername.aria2c.Aria2c
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

object Notif {
    const val ID = 4001
    const val CH_PROGRESS = "jesi_dl"
    const val CH_DONE = "jesi_done"

    fun ensure(c: Context) {
        if (Build.VERSION.SDK_INT >= 26) {
            val m = c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            m.createNotificationChannel(
                NotificationChannel(CH_PROGRESS, "التنزيلات الجارية", NotificationManager.IMPORTANCE_LOW)
            )
            m.createNotificationChannel(
                NotificationChannel(CH_DONE, "اكتمال التنزيل", NotificationManager.IMPORTANCE_DEFAULT)
            )
        }
    }

    private fun openApp(c: Context): PendingIntent {
        val i = Intent(c, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(c, 0, i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    fun progress(c: Context, title: String, text: String, pct: Int): Notification {
        val b = NotificationCompat.Builder(c, CH_PROGRESS)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(openApp(c))
        if (pct >= 0) b.setProgress(100, pct, false) else b.setProgress(0, 0, true)
        return b.build()
    }

    fun update(c: Context, title: String, text: String, pct: Int) {
        val m = c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        m.notify(ID, progress(c, title, text, pct))
    }

    fun finished(c: Context, nid: Int, title: String, text: String, uri: Uri?, mime: String?, ok: Boolean) {
        val m = c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val pi: PendingIntent = if (ok && uri != null) {
            val v = Intent(Intent.ACTION_VIEW)
            v.setDataAndType(uri, mime ?: "*/*")
            v.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            PendingIntent.getActivity(c, nid, v, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        } else {
            openApp(c)
        }
        val n = NotificationCompat.Builder(c, CH_DONE)
            .setSmallIcon(if (ok) android.R.drawable.stat_sys_download_done else android.R.drawable.stat_notify_error)
            .setContentTitle(title)
            .setContentText(text)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .build()
        m.notify(nid, n)
    }
}

class KeepAliveService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Notif.ensure(this)
        val n = Notif.progress(this, "JESI", "جارٍ التنزيل…", -1)
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(Notif.ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(Notif.ID, n)
        }
        return START_NOT_STICKY
    }
}

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pending: String? = null
    private val pool = Executors.newCachedThreadPool()
    private val ui = Handler(Looper.getMainLooper())
    private val initDone = CountDownLatch(1)

    @Volatile
    private var initError: String? = null
    private val stopReason = ConcurrentHashMap<String, String>()
    private val lastTick = ConcurrentHashMap<String, Long>()
    private val active = AtomicInteger(0)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Notif.ensure(this)
        readIntent(intent)
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 11)
        }
        pool.execute {
            try {
                YoutubeDL.getInstance().init(application)
                FFmpeg.getInstance().init(application)
                try {
                    Aria2c.getInstance().init(application)
                } catch (e: Throwable) {
                    // aria2c optional: fast mode falls back to yt-dlp fragments
                }
            } catch (e: Throwable) {
                initError = e.message ?: e.toString()
            } finally {
                initDone.countDown()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        readIntent(intent)
        if (pending != null) channel?.invokeMethod("shareReady", null)
    }

    private fun readIntent(i: Intent?) {
        if (i == null) return
        var t: String? = null
        if (i.action == Intent.ACTION_SEND) {
            t = i.getStringExtra(Intent.EXTRA_TEXT)
            if (t.isNullOrBlank()) t = i.getStringExtra(Intent.EXTRA_SUBJECT)
        } else if (i.action == Intent.ACTION_VIEW) {
            t = i.dataString
        }
        if (!t.isNullOrBlank()) {
            pending = t
            i.action = Intent.ACTION_MAIN
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "jesi/native")
        channel = ch
        ch.setMethodCallHandler { call, result -> handle(call, result) }
    }

    private fun ok(result: MethodChannel.Result, value: Any?) {
        ui.post { result.success(value) }
    }

    private fun fail(result: MethodChannel.Result, code: String, msg: String?) {
        ui.post { result.error(code, msg ?: code, null) }
    }

    private fun waitEngine(result: MethodChannel.Result): Boolean {
        initDone.await()
        val e = initError
        if (e != null) {
            fail(result, "engine", "تعذر تشغيل محرك الاستخراج: $e")
            return false
        }
        return true
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "takeShare" -> {
                val p = pending
                pending = null
                result.success(p)
            }
            "analyze" -> {
                val url = call.argument<String>("url") ?: ""
                pool.execute {
                    if (!waitEngine(result)) return@execute
                    try {
                        val req = YoutubeDLRequest(url)
                        req.addOption("--dump-single-json")
                        req.addOption("--no-playlist")
                        req.addOption("--no-warnings")
                        val resp = YoutubeDL.getInstance().execute(req)
                        ok(result, resp.out)
                    } catch (e: Throwable) {
                        fail(result, "analyze", e.message)
                    }
                }
            }
            "download" -> {
                val args = HashMap<String, Any?>()
                for (k in listOf("id", "url", "format", "audio", "mode", "title")) {
                    args[k] = call.argument<Any>(k)
                }
                pool.execute { runDownload(args, result) }
            }
            "publish" -> {
                val path = call.argument<String>("path") ?: ""
                pool.execute {
                    try {
                        val f = File(path)
                        val saved = publish(f)
                        f.delete()
                        Notif.finished(
                            this, 5000 + (path.hashCode() and 0xFFFF), "اكتمل التنزيل", f.name,
                            Uri.parse(saved["uri"] as String), saved["mime"] as String, true
                        )
                        ok(result, saved)
                    } catch (e: Throwable) {
                        fail(result, "publish", e.message)
                    }
                }
            }
            "pause" -> {
                val id = call.argument<String>("id") ?: ""
                stopReason[id] = "paused"
                pool.execute {
                    try {
                        YoutubeDL.getInstance().destroyProcessById(id)
                    } catch (e: Throwable) {
                    }
                }
                result.success(true)
            }
            "cancel" -> {
                val id = call.argument<String>("id") ?: ""
                stopReason[id] = "cancelled"
                pool.execute {
                    try {
                        YoutubeDL.getInstance().destroyProcessById(id)
                    } catch (e: Throwable) {
                    }
                    File(cacheDir, "dl/$id").deleteRecursively()
                }
                result.success(true)
            }
            "exists" -> {
                val uri = Uri.parse(call.argument<String>("uri") ?: "")
                pool.execute {
                    var found = false
                    try {
                        contentResolver.query(uri, arrayOf(MediaStore.MediaColumns._ID), null, null, null)?.use {
                            found = it.count > 0
                        }
                    } catch (e: Throwable) {
                        found = false
                    }
                    ok(result, found)
                }
            }
            "delete" -> {
                val uri = Uri.parse(call.argument<String>("uri") ?: "")
                pool.execute {
                    try {
                        ok(result, contentResolver.delete(uri, null, null) > 0)
                    } catch (e: Throwable) {
                        fail(result, "delete", e.message)
                    }
                }
            }
            "open" -> {
                try {
                    val uri = Uri.parse(call.argument<String>("uri") ?: "")
                    val mime = call.argument<String>("mime") ?: "*/*"
                    val i = Intent(Intent.ACTION_VIEW)
                    i.setDataAndType(uri, mime)
                    i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    startActivity(i)
                    result.success(true)
                } catch (e: Throwable) {
                    result.error("open", "لا يوجد تطبيق لفتح هذا الملف", null)
                }
            }
            "share" -> {
                try {
                    val uri = Uri.parse(call.argument<String>("uri") ?: "")
                    val mime = call.argument<String>("mime") ?: "*/*"
                    val i = Intent(Intent.ACTION_SEND)
                    i.type = mime
                    i.putExtra(Intent.EXTRA_STREAM, uri)
                    i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    startActivity(Intent.createChooser(i, "مشاركة"))
                    result.success(true)
                } catch (e: Throwable) {
                    result.error("share", e.message ?: "تعذرت المشاركة", null)
                }
            }
            "updateEngine" -> {
                pool.execute {
                    if (!waitEngine(result)) return@execute
                    try {
                        val st = YoutubeDL.getInstance().updateYoutubeDL(application)
                        ok(result, st?.toString() ?: "OK")
                    } catch (e: Throwable) {
                        fail(result, "update", e.message)
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun startKeepAlive() {
        if (active.incrementAndGet() == 1) {
            try {
                val i = Intent(this, KeepAliveService::class.java)
                if (Build.VERSION.SDK_INT >= 26) startForegroundService(i) else startService(i)
            } catch (e: Throwable) {
            }
        }
    }

    private fun stopKeepAlive() {
        if (active.decrementAndGet() <= 0) {
            active.set(0)
            try {
                stopService(Intent(this, KeepAliveService::class.java))
            } catch (e: Throwable) {
            }
        }
    }

    private fun runDownload(a: HashMap<String, Any?>, result: MethodChannel.Result) {
        val id = a["id"] as? String ?: return fail(result, "args", "id")
        val url = a["url"] as? String ?: return fail(result, "args", "url")
        val fmt = a["format"] as? String ?: "b"
        val audio = a["audio"] as? String
        val fast = (a["mode"] as? String) == "fast"
        val title = a["title"] as? String ?: "JESI"
        if (!waitEngine(result)) return
        stopReason.remove(id)
        startKeepAlive()
        val dir = File(cacheDir, "dl/$id")
        dir.mkdirs()
        try {
            val req = YoutubeDLRequest(url)
            req.addOption("--no-playlist")
            req.addOption("--newline")
            req.addOption("--no-mtime")
            req.addOption("--windows-filenames")
            req.addOption("-o", dir.absolutePath + "/%(title).80s.%(ext)s")
            if (audio != null) {
                req.addOption("-f", fmt)
                req.addOption("-x")
                req.addOption("--audio-format", audio)
                req.addOption("--audio-quality", "0")
            } else {
                req.addOption("-f", fmt)
                req.addOption("--merge-output-format", "mp4")
            }
            if (fast) {
                req.addOption("--concurrent-fragments", "8")
                req.addOption("--downloader", "aria2c")
                req.addOption("--downloader-args", "aria2c:-x 8 -s 8 -k 1M")
            }
            YoutubeDL.getInstance().execute(req, id) { progress, eta, line ->
                val now = System.currentTimeMillis()
                val last = lastTick[id] ?: 0L
                if (now - last > 400) {
                    lastTick[id] = now
                    val pct = if (progress >= 0) progress.toInt() else -1
                    Notif.update(this, title, line.take(80), pct)
                    val m = HashMap<String, Any?>()
                    m["id"] = id
                    m["p"] = progress.toDouble()
                    m["eta"] = eta.toInt()
                    m["line"] = line
                    ui.post { channel?.invokeMethod("progress", m) }
                }
            }
            val files = dir.listFiles()?.filter {
                it.isFile && !it.name.endsWith(".part") && !it.name.endsWith(".ytdl") &&
                    !it.name.endsWith(".json") && !it.name.contains(".part-") && !it.name.endsWith(".temp")
            } ?: emptyList()
            val f = files.maxByOrNull { it.length() }
            if (f == null || f.length() == 0L) {
                throw Exception("لم يتم إنتاج ملف. قد يكون الموقع غير مدعوم أو يحتاج تسجيل دخول.")
            }
            val saved = publish(f)
            dir.deleteRecursively()
            val uri = Uri.parse(saved["uri"] as String)
            Notif.finished(this, 5000 + (id.hashCode() and 0xFFFF), "اكتمل التنزيل", f.name, uri, saved["mime"] as String, true)
            ok(result, saved)
        } catch (e: Throwable) {
            val why = stopReason[id]
            if (why != null) {
                fail(result, why, why)
            } else {
                val msg = e.message ?: e.toString()
                Notif.finished(this, 5000 + (id.hashCode() and 0xFFFF), "فشل التنزيل", title, null, null, false)
                fail(result, "failed", msg)
            }
        } finally {
            lastTick.remove(id)
            stopKeepAlive()
        }
    }

    private fun publish(f: File): Map<String, Any?> {
        val ext = f.extension.lowercase()
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
        val collection: Uri
        val rel: String
        val kind: String
        if (mime.startsWith("video/")) {
            collection = MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            rel = Environment.DIRECTORY_MOVIES + "/JESI"
            kind = "video"
        } else if (mime.startsWith("audio/")) {
            collection = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
            rel = Environment.DIRECTORY_MUSIC + "/JESI"
            kind = "audio"
        } else if (mime.startsWith("image/")) {
            collection = MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            rel = Environment.DIRECTORY_PICTURES + "/JESI"
            kind = "image"
        } else {
            collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
            rel = Environment.DIRECTORY_DOWNLOADS + "/JESI"
            kind = "file"
        }
        val cv = ContentValues()
        cv.put(MediaStore.MediaColumns.DISPLAY_NAME, f.name)
        cv.put(MediaStore.MediaColumns.MIME_TYPE, mime)
        cv.put(MediaStore.MediaColumns.RELATIVE_PATH, rel)
        cv.put(MediaStore.MediaColumns.IS_PENDING, 1)
        val uri = contentResolver.insert(collection, cv) ?: throw Exception("تعذر إنشاء الملف في التخزين")
        contentResolver.openOutputStream(uri)?.use { out ->
            f.inputStream().use { it.copyTo(out) }
        } ?: throw Exception("تعذر الكتابة في التخزين")
        val done = ContentValues()
        done.put(MediaStore.MediaColumns.IS_PENDING, 0)
        contentResolver.update(uri, done, null, null)
        val m = HashMap<String, Any?>()
        m["uri"] = uri.toString()
        m["name"] = f.name
        m["mime"] = mime
        m["size"] = f.length()
        m["kind"] = kind
        return m
    }
}
