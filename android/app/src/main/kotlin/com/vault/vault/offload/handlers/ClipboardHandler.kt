package com.vault.vault.offload.handlers

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import com.vault.vault.offload.OffloadHandler
import com.vault.vault.offload.OffloadRequest
import com.vault.vault.offload.OffloadResponse
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

class ClipboardHandler(private val context: Context) : OffloadHandler {
    private val main = Handler(Looper.getMainLooper())

    override fun handle(req: OffloadRequest): OffloadResponse {
        val sub = req.argv.getOrNull(1) ?: "get"
        return when (sub) {
            "smoke" -> smoke()
            "get" -> OffloadResponse.ok(readClipboard())
            "set" -> {
                val text = req.argv.drop(2).joinToString(" ")
                writeClipboard(text)
                OffloadResponse.ok("ok")
            }
            else -> OffloadResponse.unknown("clipboard: unknown subcommand '$sub'")
        }
    }

    private fun smoke(): OffloadResponse {
        val marker = "vault-clipboard-smoke"
        writeClipboard(marker)
        val got = readClipboard()
        return if (got == marker) {
            OffloadResponse.ok("clipboard smoke ok")
        } else {
            OffloadResponse.error(1, "clipboard smoke failed: got='$got'")
        }
    }

    private fun readClipboard(): String {
        val out = AtomicReference("")
        val latch = CountDownLatch(1)
        main.post {
            try {
                val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                val clip = cm.primaryClip
                out.set(
                    if (clip != null && clip.itemCount > 0) {
                        clip.getItemAt(0).coerceToText(context)?.toString() ?: ""
                    } else {
                        ""
                    },
                )
            } finally {
                latch.countDown()
            }
        }
        latch.await(5, TimeUnit.SECONDS)
        return out.get()
    }

    private fun writeClipboard(text: String) {
        val latch = CountDownLatch(1)
        main.post {
            try {
                val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                cm.setPrimaryClip(ClipData.newPlainText("vault", text))
            } finally {
                latch.countDown()
            }
        }
        latch.await(5, TimeUnit.SECONDS)
    }
}
