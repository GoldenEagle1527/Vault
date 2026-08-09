package com.vault.vault.offload.handlers

import android.content.Context
import android.content.pm.PackageManager
import com.vault.vault.offload.OffloadHandler
import com.vault.vault.offload.OffloadRequest
import com.vault.vault.offload.OffloadResponse
import org.json.JSONObject

/**
 * Wave4 `vault-shizuku` — status/smoke skeleton without bundling Shizuku AAR.
 *
 * Detects whether the Shizuku manager app is installed; binder API is deferred.
 * Always exits **0** with `limited:true` (bridge stub is present).
 */
class ShizukuHandler(private val context: Context) : OffloadHandler {
    override fun handle(req: OffloadRequest): OffloadResponse {
        val sub = req.argv.getOrNull(1) ?: "smoke"
        return when (sub) {
            "smoke", "status" -> status()
            else -> OffloadResponse.unknown("shizuku: unknown subcommand '$sub'")
        }
    }

    private fun status(): OffloadResponse {
        val installed = findShizukuPackage()
        val available = installed != null
        val body = JSONObject()
            .put("ok", true)
            .put("available", available)
            .put("limited", true)
            .put("package", installed ?: JSONObject.NULL)
            .put(
                "note",
                if (available) {
                    "Shizuku app detected; binder API not bundled in Wave4 (install Shizuku and future binder)"
                } else {
                    "Shizuku not bundled; install Shizuku and future binder"
                },
            )
        return OffloadResponse.ok(body.toString())
    }

    private fun findShizukuPackage(): String? {
        val candidates = listOf(
            "moe.shizuku.privileged.api",
            "moe.shizuku.manager",
        )
        val pm = context.packageManager
        for (pkg in candidates) {
            try {
                pm.getPackageInfo(pkg, 0)
                return pkg
            } catch (_: PackageManager.NameNotFoundException) {
                // try next
            }
        }
        return null
    }
}
