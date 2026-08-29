package com.vault.vault

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

/**
 * Stream a host file into the public Downloads collection (user-initiated export).
 */
class FileExportPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var appContext: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "saveToDownloads" -> {
                val displayName = call.argument<String>("displayName")?.trim().orEmpty()
                val sourcePath = call.argument<String>("sourcePath")?.trim().orEmpty()
                val mimeType = call.argument<String>("mimeType")
                if (displayName.isEmpty() || sourcePath.isEmpty()) {
                    result.error("bad_args", "displayName and sourcePath required", null)
                    return
                }
                try {
                    result.success(saveToDownloads(displayName, sourcePath, mimeType))
                } catch (e: Exception) {
                    result.error("export_failed", e.message, null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun saveToDownloads(
        displayName: String,
        sourcePath: String,
        mimeType: String?,
    ): String {
        val source = File(sourcePath)
        if (!source.isFile) {
            throw IllegalStateException("source is not a file: $sourcePath")
        }
        val mime = mimeType?.takeIf { it.isNotBlank() } ?: guessMime(displayName)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, displayName)
                put(MediaStore.Downloads.MIME_TYPE, mime)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val resolver = appContext.contentResolver
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("MediaStore insert failed")
            resolver.openOutputStream(uri)?.use { out ->
                FileInputStream(source).use { input -> input.copyTo(out) }
            } ?: throw IllegalStateException("unable to open Downloads stream")
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            return uri.toString()
        }
        val downloads = Environment.getExternalStoragePublicDirectory(
            Environment.DIRECTORY_DOWNLOADS,
        )
        if (!downloads.exists()) downloads.mkdirs()
        val dest = uniqueFile(downloads, displayName)
        source.inputStream().use { input ->
            dest.outputStream().use { output -> input.copyTo(output) }
        }
        return dest.absolutePath
    }

    private fun uniqueFile(dir: File, displayName: String): File {
        var dest = File(dir, displayName)
        if (!dest.exists()) return dest
        val dot = displayName.lastIndexOf('.')
        val stem = if (dot > 0) displayName.substring(0, dot) else displayName
        val ext = if (dot > 0) displayName.substring(dot) else ""
        var i = 2
        while (true) {
            dest = File(dir, "$stem-$i$ext")
            if (!dest.exists()) return dest
            i++
            if (i > 999) throw IllegalStateException("unable to allocate Downloads name")
        }
    }

    private fun guessMime(name: String): String {
        val ext = name.substringAfterLast('.', "").lowercase()
        if (ext.isEmpty()) return "application/octet-stream"
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
            ?: "application/octet-stream"
    }

    companion object {
        const val CHANNEL = "vault.files/export"
    }
}
