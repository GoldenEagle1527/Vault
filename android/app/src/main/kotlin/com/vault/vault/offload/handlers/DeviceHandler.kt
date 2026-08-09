package com.vault.vault.offload.handlers

import android.os.Build
import com.vault.vault.offload.OffloadHandler
import com.vault.vault.offload.OffloadRequest
import com.vault.vault.offload.OffloadResponse

class DeviceHandler : OffloadHandler {
    override fun handle(req: OffloadRequest): OffloadResponse {
        val sub = req.argv.getOrNull(1) ?: "info"
        return when (sub) {
            "smoke", "info" -> {
                val text = buildString {
                    append("manufacturer=").append(Build.MANUFACTURER).append('\n')
                    append("model=").append(Build.MODEL).append('\n')
                    append("device=").append(Build.DEVICE).append('\n')
                    append("sdk=").append(Build.VERSION.SDK_INT).append('\n')
                    append("release=").append(Build.VERSION.RELEASE).append('\n')
                    if (sub == "smoke") append("device smoke ok\n")
                }
                OffloadResponse.ok(text)
            }
            else -> OffloadResponse.unknown("device: unknown subcommand '$sub'")
        }
    }
}
