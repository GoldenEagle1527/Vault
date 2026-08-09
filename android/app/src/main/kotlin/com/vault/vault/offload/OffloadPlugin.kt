package com.vault.vault.offload

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * MethodChannel `vault.offload/host`:
 * - startServer / stopServer / getPort
 * - setBypassAll
 * - checkPermission (local probe via gate; prefer Dart manager for app logic)
 *
 * Permission checks from [OffloadServer] go Kotlin→Dart on
 * [OffloadGate.PERMISSION_CHANNEL] (`vault.offload/permission`), whose
 * MethodCallHandler is owned by Flutter (not this plugin).
 */
class OffloadPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var permissionChannel: MethodChannel
    private lateinit var appContext: Context
    private val gate = OffloadGate()
    private var server: OffloadServer? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
        // Dart owns the handler; Kotlin only invokes checkPermission.
        permissionChannel = MethodChannel(
            binding.binaryMessenger,
            OffloadGate.PERMISSION_CHANNEL,
        )
        gate.attachChannel(permissionChannel)
        server = OffloadServer(appContext, gate)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        server?.stop()
        server = null
        gate.detachChannel()
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startServer" -> {
                try {
                    val port = server!!.start()
                    result.success(port)
                } catch (e: Exception) {
                    result.error("start", e.message, null)
                }
            }
            "stopServer" -> {
                server?.stop()
                result.success(true)
            }
            "getPort" -> {
                val p = server?.port ?: 0
                result.success(if (server?.isRunning == true) p else 0)
            }
            "checkPermission" -> {
                val capability = call.argument<String>("capability") ?: ""
                val sessionId = call.argument<String>("sessionId") ?: ""
                result.success(gate.checkLocal(capability, sessionId))
            }
            "setBypassAll" -> {
                val bypass = call.argument<Boolean>("bypass") ?: true
                gate.bypassAll = bypass
                result.success(gate.bypassAll)
            }
            else -> result.notImplemented()
        }
    }

    companion object {
        const val CHANNEL = "vault.offload/host"
    }
}
