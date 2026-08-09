package com.vault.vault.offload.handlers

import com.vault.vault.offload.OffloadHandler
import com.vault.vault.offload.OffloadRequest
import com.vault.vault.offload.OffloadResponse
import org.json.JSONObject

/**
 * vault-config / vault_config — master switch is enforced by [com.vault.vault.offload.OffloadGate]
 * via Dart OffloadPermissionManager before this handler runs.
 *
 * Writes (set) go through Flutter Settings / AgentSettingsStore (secure storage).
 * Kotlin exposes smoke + status (+ redacted get stub). Never returns API keys.
 */
class VaultConfigHandler : OffloadHandler {
    override fun handle(req: OffloadRequest): OffloadResponse {
        val sub = req.argv.getOrNull(1) ?: "smoke"
        return when (sub) {
            "smoke" -> OffloadResponse.ok("vault_config smoke ok")
            "status" -> status()
            "get" -> get()
            "set" -> OffloadResponse.error(
                1,
                JSONObject()
                    .put("error", "writes_via_flutter")
                    .put(
                        "message",
                        "vault-config set is owned by Flutter Settings / AgentSettingsStore; " +
                            "Kotlin bridge is read-status only",
                    )
                    .toString(),
            )
            else -> OffloadResponse.unknown("vault_config: unknown subcommand '$sub'")
        }
    }

    /**
     * Reaching this handler means the gate allowed capability `vault_config`
     * (or bypassAll). Mirror that as enabled=true for the guest.
     */
    private fun status(): OffloadResponse {
        val body = JSONObject()
            .put("vault_config_enabled", true)
            .put("capability", "vault_config")
            .put("writes", "flutter_settings")
            .put("note", "Master switch enforced by OffloadGate → Dart OffloadPermissionManager")
        return OffloadResponse.ok(body.toString())
    }

    /**
     * Non-secret settings stub. Model/baseUrl live in FlutterSecureStorage and are
     * not readable from Kotlin without a MethodChannel; never surface API keys.
     */
    private fun get(): OffloadResponse {
        val body = JSONObject()
            .put("model", JSONObject.NULL)
            .put("baseUrl", JSONObject.NULL)
            .put("apiKey", REDACTED)
            .put(
                "note",
                "Non-secret LLM settings are stored in Flutter AgentSettingsStore; " +
                    "use Flutter Settings to read/write. apiKey is always redacted.",
            )
        return OffloadResponse.ok(body.toString())
    }

    companion object {
        private const val REDACTED = "[redacted]"
    }
}
