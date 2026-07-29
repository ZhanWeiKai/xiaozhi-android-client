package com.lhht.ai_assistant

import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.AlarmClock
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity : FlutterActivity() {

    private val CHANNEL = "device.mcp.tools"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveImageToGallery" -> {
                        val srcPath = call.argument<String>("path")
                        val name = call.argument<String>("name")
                            ?: "IMG_${System.currentTimeMillis()}.jpg"
                        if (srcPath == null) {
                            result.error("no_path", "missing path", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val saved = saveImage(File(srcPath), name)
                            result.success(mapOf("uri" to saved))
                        } catch (e: Exception) {
                            result.error("save_failed", e.message, null)
                        }
                    }
                    "setSystemAlarm" -> {
                        val hour = call.argument<Int>("hour")
                        val minute = call.argument<Int>("minute")
                        val label = call.argument<String>("label") ?: ""
                        if (hour == null || minute == null) {
                            result.error("no_time", "missing hour/minute", null)
                            return@setMethodCallHandler
                        }
                        try {
                            setSystemAlarm(hour, minute, label)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("alarm_failed", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// 把图片写入相册（DCIM/Camera）。
    /// Android 10+ 走 MediaStore（RELATIVE_PATH），老版本直接写公共 DCIM 目录。
    private fun saveImage(src: File, name: String): String {
        val resolver = applicationContext.contentResolver
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, name)
                put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                put(MediaStore.Images.Media.RELATIVE_PATH, "DCIM/Camera")
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
            val uri = resolver.insert(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values
            ) ?: throw Exception("MediaStore insert 失败")
            resolver.openOutputStream(uri)?.use { out ->
                FileInputStream(src).use { it.copyTo(out) }
            } ?: throw Exception("打开输出流失败")
            values.clear()
            values.put(MediaStore.Images.Media.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            uri.toString()
        } else {
            @Suppress("DEPRECATION")
            val dir = File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM),
                "Camera"
            )
            if (!dir.exists()) dir.mkdirs()
            val dest = File(dir, name)
            FileInputStream(src).use { input ->
                dest.outputStream().use { input.copyTo(it) }
            }
            // 触发媒体扫描，让相册立刻看到
            @Suppress("DEPRECATION")
            val scanIntent = Intent(Intent.ACTION_MEDIA_SCANNER_SCAN_FILE)
            scanIntent.data = Uri.fromFile(dest)
            sendBroadcast(scanIntent)
            dest.absolutePath
        }
    }

    /// 设置系统时钟 App 的闹钟（ACTION_SET_ALARM 意图）。
    /// 延迟 ~4s 再跳时钟 App：工具结果要经 worker→tenclass→LLM→TTS 才到用户，
    /// 留足时间让 AI 先把"需要手动切回"的提示说出来，再跳转。
    /// Android 16 的 BAL 限制下跳过去后无法自动切回，需用户手动返回。
    private fun setSystemAlarm(hour: Int, minute: Int, label: String) {
        val intent = Intent(AlarmClock.ACTION_SET_ALARM).apply {
            putExtra(AlarmClock.EXTRA_HOUR, hour)
            putExtra(AlarmClock.EXTRA_MINUTES, minute)
            putExtra(AlarmClock.EXTRA_MESSAGE, label)
            putExtra(AlarmClock.EXTRA_VIBRATE, true)
            putExtra(AlarmClock.EXTRA_SKIP_UI, true)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }
        Handler(Looper.getMainLooper()).postDelayed({
            try {
                startActivity(intent)
            } catch (_: Exception) {
            }
        }, 4000)
    }
}
