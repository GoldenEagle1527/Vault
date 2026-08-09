package com.vault.vault.offload

import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject

data class OffloadRequest(
    val argv: List<String>,
    val cwd: String,
    val env: Map<String, String>,
    val sessionId: String,
) {
    companion object {
        fun fromJson(raw: String): OffloadRequest {
            val obj = JSONObject(raw)
            val argvJson = obj.optJSONArray("argv") ?: JSONArray()
            val argv = buildList {
                for (i in 0 until argvJson.length()) {
                    add(argvJson.optString(i, ""))
                }
            }
            val envJson = obj.optJSONObject("env")
            val env = mutableMapOf<String, String>()
            if (envJson != null) {
                val keys = envJson.keys()
                while (keys.hasNext()) {
                    val k = keys.next()
                    env[k] = envJson.optString(k, "")
                }
            }
            val sessionId = obj.optString("sessionId", "").ifEmpty {
                env["VAULT_CHAT_SESSION_ID"] ?: ""
            }
            return OffloadRequest(
                argv = argv,
                cwd = obj.optString("cwd", "/"),
                env = env,
                sessionId = sessionId,
            )
        }
    }
}

data class OffloadResponse(
    val exitCode: Int,
    val stdout: String,
) {
    fun toJsonLine(): String {
        val b64 = Base64.encodeToString(
            stdout.toByteArray(Charsets.UTF_8),
            Base64.NO_WRAP,
        )
        return JSONObject()
            .put("exitCode", exitCode)
            .put("stdout", stdout)
            .put("stdoutB64", b64)
            .toString()
    }

    companion object {
        const val PERMISSION_DENIED = 126
        const val UNSUPPORTED = 125
        const val UNKNOWN_COMMAND = 127

        fun ok(stdout: String = "") = OffloadResponse(0, stdout)
        fun permissionDenied(msg: String = "permission_denied") =
            OffloadResponse(PERMISSION_DENIED, msg)
        fun unsupported(msg: String = "unsupported") =
            OffloadResponse(UNSUPPORTED, msg)
        fun unknown(msg: String = "unknown command") =
            OffloadResponse(UNKNOWN_COMMAND, msg)
        fun error(exitCode: Int, msg: String) = OffloadResponse(exitCode, msg)
    }
}

fun interface OffloadHandler {
    fun handle(req: OffloadRequest): OffloadResponse
}
