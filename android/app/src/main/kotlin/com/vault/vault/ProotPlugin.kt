package com.vault.vault

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Thin bridge for proot sandbox: nativeLibraryDir, filesDir, page size,
 * foreground-service lifecycle, battery-optimization settings intent.
 */
class ProotPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
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
            "getNativeLibraryDir" -> {
                result.success(appContext.applicationInfo.nativeLibraryDir)
            }
            "getFilesDir" -> {
                result.success(appContext.filesDir.absolutePath)
            }
            "getPageSize" -> {
                result.success(pageSizeBytes())
            }
            "getAbi" -> {
                result.success(Build.SUPPORTED_ABIS.firstOrNull() ?: "unknown")
            }
            "startForegroundService" -> {
                val intent = Intent(appContext, WorkspaceForegroundService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    appContext.startForegroundService(intent)
                } else {
                    appContext.startService(intent)
                }
                result.success(true)
            }
            "stopForegroundService" -> {
                val intent = Intent(appContext, WorkspaceForegroundService::class.java)
                appContext.stopService(intent)
                result.success(true)
            }
            "openBatteryOptimizationSettings" -> {
                try {
                    val pkg = appContext.packageName
                    val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    // Prefer per-app request when allowed; fall back to list.
                    val request = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                        data = Uri.parse("package:$pkg")
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    val pm = appContext.getSystemService(Context.POWER_SERVICE) as PowerManager
                    if (!pm.isIgnoringBatteryOptimizations(pkg)) {
                        appContext.startActivity(request)
                    } else {
                        appContext.startActivity(intent)
                    }
                    result.success(true)
                } catch (e: Exception) {
                    result.error("battery", e.message, null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun pageSizeBytes(): Int {
        return try {
            android.system.Os.sysconf(android.system.OsConstants._SC_PAGESIZE).toInt()
        } catch (_: Throwable) {
            try {
                val proc = Runtime.getRuntime().exec(arrayOf("/system/bin/getconf", "PAGE_SIZE"))
                val text = proc.inputStream.bufferedReader().readText().trim()
                proc.waitFor()
                text.toIntOrNull() ?: 4096
            } catch (_: Throwable) {
                4096
            }
        }
    }

    companion object {
        const val CHANNEL = "vault.sandbox/proot"
    }
}
