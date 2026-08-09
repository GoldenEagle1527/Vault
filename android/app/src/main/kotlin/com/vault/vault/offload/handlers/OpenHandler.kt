package com.vault.vault.offload.handlers

import android.content.Context
import android.content.Intent
import android.net.Uri
import com.vault.vault.offload.OffloadHandler
import com.vault.vault.offload.OffloadRequest
import com.vault.vault.offload.OffloadResponse

class OpenHandler(private val context: Context) : OffloadHandler {
    override fun handle(req: OffloadRequest): OffloadResponse {
        val sub = req.argv.getOrNull(1)
        return when {
            sub == null || sub == "smoke" -> {
                // Smoke: validate a well-known URL without launching if possible.
                val url = "https://example.com"
                if (!isValidHttpUrl(url)) {
                    OffloadResponse.error(1, "open smoke: invalid url")
                } else {
                    OffloadResponse.ok("open smoke ok (url validated, not launched)")
                }
            }
            sub == "url" || looksLikeUrl(sub) -> {
                val url = if (sub == "url") {
                    req.argv.getOrNull(2)
                        ?: return OffloadResponse.error(1, "open url: missing URL")
                } else {
                    sub
                }
                openUrl(url)
            }
            else -> OffloadResponse.unknown("open: unknown subcommand '$sub'")
        }
    }

    private fun openUrl(url: String): OffloadResponse {
        if (!isValidHttpUrl(url) && !url.startsWith("mailto:", ignoreCase = true)) {
            return OffloadResponse.error(1, "open: unsupported or invalid URL")
        }
        return try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
            OffloadResponse.ok("opened $url")
        } catch (e: Exception) {
            OffloadResponse.error(1, "open failed: ${e.message}")
        }
    }

    private fun looksLikeUrl(s: String): Boolean =
        s.startsWith("http://", ignoreCase = true) ||
            s.startsWith("https://", ignoreCase = true) ||
            s.startsWith("mailto:", ignoreCase = true)

    private fun isValidHttpUrl(url: String): Boolean {
        return try {
            val u = Uri.parse(url)
            val scheme = u.scheme?.lowercase()
            (scheme == "http" || scheme == "https") && !u.host.isNullOrBlank()
        } catch (_: Throwable) {
            false
        }
    }
}
