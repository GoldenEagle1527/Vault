package com.vault.vault.offload.handlers

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import com.vault.vault.offload.OffloadHandler
import com.vault.vault.offload.OffloadRequest
import com.vault.vault.offload.OffloadResponse
import org.json.JSONObject

/**
 * Speech recognition probe. Full listen/transcribe loops are out of scope for Wave3;
 * smoke checks mic permission + recognizer availability.
 *
 * Missing RECORD_AUDIO → exit 1 with os_permission_required JSON (not 125).
 */
class SpeechHandler(private val context: Context) : OffloadHandler {
    override fun handle(req: OffloadRequest): OffloadResponse {
        val sub = req.argv.getOrNull(1) ?: "smoke"
        return when (sub) {
            "smoke" -> smoke()
            else -> OffloadResponse.unknown("speech: unknown subcommand '$sub'")
        }
    }

    private fun smoke(): OffloadResponse {
        if (!hasMicPermission()) {
            return permissionNeeded()
        }
        val available = try {
            SpeechRecognizer.isRecognitionAvailable(context)
        } catch (e: Exception) {
            return OffloadResponse.error(1, "speech smoke failed: ${e.message}")
        }
        if (!available) {
            // Availability failure is not "unsupported platform" (125); report as soft fail.
            val body = JSONObject()
                .put("error", "recognizer_unavailable")
                .put("message", "SpeechRecognizer.isRecognitionAvailable returned false")
                .put("hasMicPermission", true)
            return OffloadResponse.error(1, body.toString())
        }
        val activityAvailable = canResolveRecognizeIntent()
        val body = JSONObject()
            .put("ok", true)
            .put("hasMicPermission", true)
            .put("recognizerAvailable", true)
            .put("recognizeIntentResolvable", activityAvailable)
        return OffloadResponse.ok("speech smoke ok $body")
    }

    private fun hasMicPermission(): Boolean =
        context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    private fun canResolveRecognizeIntent(): Boolean {
        return try {
            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            context.packageManager.resolveActivity(intent, 0) != null
        } catch (_: Exception) {
            false
        }
    }

    private fun permissionNeeded(detail: String? = null): OffloadResponse {
        val msg = JSONObject()
            .put("error", "os_permission_required")
            .put("permission", "RECORD_AUDIO")
            .put(
                "message",
                "Grant microphone permission in Android Settings for Vault" +
                    (if (detail.isNullOrBlank()) "" else ": $detail"),
            )
            .toString()
        return OffloadResponse.error(1, msg)
    }
}
