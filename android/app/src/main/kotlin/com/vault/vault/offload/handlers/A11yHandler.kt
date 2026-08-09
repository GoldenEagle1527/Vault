package com.vault.vault.offload.handlers

import android.content.Context
import android.provider.Settings
import android.text.TextUtils
import com.vault.vault.offload.OffloadHandler
import com.vault.vault.offload.OffloadRequest
import com.vault.vault.offload.OffloadResponse
import com.vault.vault.offload.VaultAccessibilityService
import org.json.JSONObject

/**
 * Wave4 `vault-a11y` — report whether Vault's AccessibilityService is enabled.
 *
 * MVP: smoke/status only (no tap/swipe automation).
 * If the service is not enabled: exit **1** with JSON pointing at Settings
 * (not 125 — the bridge is implemented; OS enablement is missing).
 */
class A11yHandler(private val context: Context) : OffloadHandler {
    override fun handle(req: OffloadRequest): OffloadResponse {
        val sub = req.argv.getOrNull(1) ?: "smoke"
        return when (sub) {
            "smoke", "status" -> status()
            else -> OffloadResponse.unknown("a11y: unknown subcommand '$sub'")
        }
    }

    private fun status(): OffloadResponse {
        val component = componentName()
        val enabled = isServiceEnabled(component)
        val body = JSONObject()
            .put("ok", enabled)
            .put("enabled", enabled)
            .put("service", component)
            .put("limited", true)
            .put(
                "note",
                if (enabled) {
                    "Accessibility service enabled (Wave4 status-only; no UI automation)"
                } else {
                    "Enable Vault in Android Settings → Accessibility → Installed apps / Downloaded apps"
                },
            )
            .put("settingsAction", "android.settings.ACCESSIBILITY_SETTINGS")

        return if (enabled) {
            OffloadResponse.ok(body.toString())
        } else {
            // Exit 1 (not 125): bridge exists; user must enable the service.
            OffloadResponse.error(1, body.toString())
        }
    }

    private fun componentName(): String =
        "${context.packageName}/${VaultAccessibilityService::class.java.name}"

    private fun isServiceEnabled(expected: String): Boolean {
        val flat = try {
            Settings.Secure.getString(
                context.contentResolver,
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
            )
        } catch (_: Exception) {
            null
        }
        if (flat.isNullOrBlank()) return false

        val splitter = TextUtils.SimpleStringSplitter(':')
        splitter.setString(flat)
        while (splitter.hasNext()) {
            val enabled = splitter.next()
            if (enabled.equals(expected, ignoreCase = true)) return true
            // Some OEMs store short form ".VaultAccessibilityService"
            if (enabled.equals(
                    "${context.packageName}/.offload.VaultAccessibilityService",
                    ignoreCase = true,
                )
            ) {
                return true
            }
            if (enabled.endsWith("/${VaultAccessibilityService::class.java.name}", ignoreCase = true) &&
                enabled.startsWith(context.packageName, ignoreCase = true)
            ) {
                return true
            }
        }
        return false
    }
}
