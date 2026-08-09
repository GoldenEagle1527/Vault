package com.vault.vault.offload

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Permission gate for host offload.
 *
 * Invokes Flutter on [PERMISSION_CHANNEL] (`vault.offload/permission`) via
 * `checkPermission`. Dart owns that channel's MethodCallHandler and consults
 * [OffloadPermissionManager]. Missing session / deny → false (exit 126).
 *
 * [bypassAll] defaults true until Dart calls `setBypassAll(false)` after
 * registering the permission handler.
 */
class OffloadGate {
    @Volatile
    var bypassAll: Boolean = true

    /** Channel name must match Dart [OffloadPermissionChannel]. */
    private var channel: MethodChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    fun attachChannel(channel: MethodChannel) {
        this.channel = channel
    }

    fun detachChannel() {
        channel = null
    }

    /**
     * @param capability PermissionRegistry id from [OffloadServer.capabilityForBasename],
     *   e.g. "clipboard", "device_info", "open_url", "calendar", "host_files",
     *   "vault_config", "speak", "speech", "a11y", "shizuku" — never the naive
     *   `vault-` strip (`vault-config` must be `vault_config`, not `config`).
     * @return true if allowed
     */
    fun check(capability: String, sessionId: String): Boolean {
        if (bypassAll) return true
        // Fail closed: no Flutter handler yet, or blank session (126 path).
        if (sessionId.isBlank()) return false
        val ch = channel ?: return false
        val allowed = AtomicBoolean(false)
        val latch = CountDownLatch(1)
        val args = hashMapOf(
            "capability" to capability,
            "sessionId" to sessionId,
        )
        mainHandler.post {
            try {
                ch.invokeMethod(
                    "checkPermission",
                    args,
                    object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            when (result) {
                                is Boolean -> allowed.set(result)
                                is Map<*, *> -> {
                                    val v = result["allowed"]
                                    allowed.set(v == true || v == "true")
                                }
                                else -> allowed.set(false)
                            }
                            latch.countDown()
                        }

                        override fun error(
                            errorCode: String,
                            errorMessage: String?,
                            errorDetails: Any?,
                        ) {
                            allowed.set(false)
                            latch.countDown()
                        }

                        override fun notImplemented() {
                            allowed.set(false)
                            latch.countDown()
                        }
                    },
                )
            } catch (_: Throwable) {
                allowed.set(false)
                latch.countDown()
            }
        }
        latch.await(8, TimeUnit.SECONDS)
        return allowed.get()
    }

    /** Host→Flutter style check used by MethodChannel from Dart (mirror / probe). */
    fun checkLocal(capability: String, sessionId: String): Map<String, Any> {
        val allowed = check(capability, sessionId)
        return mapOf(
            "allowed" to allowed,
            "bypassAll" to bypassAll,
            "capability" to capability,
            "sessionId" to sessionId,
            "exitCodeIfDenied" to OffloadResponse.PERMISSION_DENIED,
        )
    }

    companion object {
        const val PERMISSION_CHANNEL = "vault.offload/permission"
    }
}
