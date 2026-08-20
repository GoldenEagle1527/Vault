package com.vault.vault

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Thin bridge for proot sandbox: nativeLibraryDir, filesDir, page size,
 * foreground-service lifecycle, battery-optimization / notification keep-alive.
 */
class ProotPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {
    private lateinit var channel: MethodChannel
    private lateinit var appContext: Context
    private var activity: Activity? = null
    private var notificationPermissionResult: MethodChannel.Result? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
        instance = this
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        if (instance === this) instance = null
        channel.setMethodCallHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != NOTIFICATION_PERMISSION_REQ) return false
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        notificationPermissionResult?.success(granted)
        notificationPermissionResult = null
        return true
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
            "getKeepAliveStatus" -> {
                result.success(readKeepAliveStatus())
            }
            "startForegroundService" -> {
                try {
                    startWorkspaceForegroundService(
                        title = call.argument("title"),
                        text = call.argument("text"),
                        showStopSite = call.argument<Boolean>("showStopSite") == true,
                    )
                    result.success(true)
                } catch (e: Exception) {
                    result.error("fgs", e.message, null)
                }
            }
            "updateForegroundService" -> {
                try {
                    startWorkspaceForegroundService(
                        title = call.argument("title"),
                        text = call.argument("text"),
                        showStopSite = call.argument<Boolean>("showStopSite") == true,
                    )
                    result.success(true)
                } catch (e: Exception) {
                    result.error("fgs", e.message, null)
                }
            }
            "stopForegroundService" -> {
                val intent = Intent(appContext, WorkspaceForegroundService::class.java)
                appContext.stopService(intent)
                result.success(true)
            }
            "requestNotificationPermission" -> {
                requestNotificationPermission(result)
            }
            "requestIgnoreBatteryOptimizations" -> {
                try {
                    result.success(openBatteryOptimizationRequest())
                } catch (e: Exception) {
                    result.error("battery", e.message, null)
                }
            }
            "openBatteryOptimizationSettings" -> {
                try {
                    openBatteryOptimizationSettings()
                    result.success(true)
                } catch (e: Exception) {
                    result.error("battery", e.message, null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun readKeepAliveStatus(): Map<String, Any> {
        val pkg = appContext.packageName
        val pm = appContext.getSystemService(Context.POWER_SERVICE) as PowerManager
        val notificationsEnabled = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            NotificationManagerCompat.from(appContext).areNotificationsEnabled()
        } else {
            true
        }
        return mapOf(
            "notificationsEnabled" to notificationsEnabled,
            "batteryOptimizationIgnored" to pm.isIgnoringBatteryOptimizations(pkg),
            "foregroundServiceRunning" to WorkspaceForegroundService.isRunning,
        )
    }

    private fun startWorkspaceForegroundService(
        title: String?,
        text: String?,
        showStopSite: Boolean,
    ) {
        val intent = Intent(appContext, WorkspaceForegroundService::class.java)
        if (title != null) intent.putExtra(WorkspaceForegroundService.EXTRA_TITLE, title)
        if (text != null) intent.putExtra(WorkspaceForegroundService.EXTRA_TEXT, text)
        intent.putExtra(WorkspaceForegroundService.EXTRA_SHOW_STOP_SITE, showStopSite)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            appContext.startForegroundService(intent)
        } else {
            appContext.startService(intent)
        }
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(true)
            return
        }
        val act = activity
        if (act == null) {
            result.error("no_activity", "需要前台 Activity 才能请求通知权限", null)
            return
        }
        if (ContextCompat.checkSelfPermission(
                act,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        notificationPermissionResult = result
        ActivityCompat.requestPermissions(
            act,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQ,
        )
    }

    /** Returns whether battery optimization is already ignored. */
    private fun openBatteryOptimizationRequest(): Boolean {
        val pkg = appContext.packageName
        val pm = appContext.getSystemService(Context.POWER_SERVICE) as PowerManager
        if (pm.isIgnoringBatteryOptimizations(pkg)) return true
        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
            data = Uri.parse("package:$pkg")
            if (activity == null) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val launcher = activity ?: appContext
        launcher.startActivity(intent)
        return false
    }

    private fun openBatteryOptimizationSettings() {
        val pkg = appContext.packageName
        val pm = appContext.getSystemService(Context.POWER_SERVICE) as PowerManager
        if (!pm.isIgnoringBatteryOptimizations(pkg)) {
            openBatteryOptimizationRequest()
            return
        }
        val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        (activity ?: appContext).startActivity(intent)
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
        private const val NOTIFICATION_PERMISSION_REQ = 7302

        @Volatile
        private var instance: ProotPlugin? = null

        fun notifyKeepAliveAction(action: String) {
            try {
                instance?.channel?.invokeMethod("onKeepAliveAction", action)
            } catch (_: Exception) {
            }
        }
    }
}
