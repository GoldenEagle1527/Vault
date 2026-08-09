package com.vault.vault.offload.handlers

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import com.vault.vault.offload.OffloadHandler
import com.vault.vault.offload.OffloadRequest
import com.vault.vault.offload.OffloadResponse
import java.util.Locale
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

class SpeakHandler(private val context: Context) : OffloadHandler {
    private val main = Handler(Looper.getMainLooper())

    override fun handle(req: OffloadRequest): OffloadResponse {
        val sub = req.argv.getOrNull(1) ?: "smoke"
        return when (sub) {
            "smoke" -> smoke()
            "say" -> {
                val text = req.argv.drop(2).joinToString(" ").trim()
                if (text.isEmpty()) {
                    OffloadResponse.error(1, "speak say: missing text")
                } else {
                    say(text)
                }
            }
            else -> OffloadResponse.unknown("speak: unknown subcommand '$sub'")
        }
    }

    private fun smoke(): OffloadResponse {
        return withTts { tts ->
            val lang = tts.setLanguage(Locale.getDefault())
            if (lang == TextToSpeech.LANG_MISSING_DATA || lang == TextToSpeech.LANG_NOT_SUPPORTED) {
                OffloadResponse.ok("speak smoke ok (engine ready, language limited)")
            } else {
                OffloadResponse.ok("speak smoke ok")
            }
        }
    }

    private fun say(text: String): OffloadResponse {
        val clipped = if (text.length > MAX_CHARS) text.substring(0, MAX_CHARS) else text
        return withTts { tts ->
            tts.language = Locale.getDefault()
            val done = CountDownLatch(1)
            val err = AtomicReference<String?>(null)
            val utteranceId = UUID.randomUUID().toString()
            tts.setOnUtteranceProgressListener(
                object : UtteranceProgressListener() {
                    override fun onStart(utteranceId: String?) {}
                    override fun onDone(utteranceId: String?) {
                        done.countDown()
                    }
                    @Deprecated("Deprecated in Java")
                    override fun onError(utteranceId: String?) {
                        err.set("tts utterance error")
                        done.countDown()
                    }
                    override fun onError(utteranceId: String?, errorCode: Int) {
                        err.set("tts utterance error code=$errorCode")
                        done.countDown()
                    }
                },
            )
            val result = tts.speak(clipped, TextToSpeech.QUEUE_FLUSH, null, utteranceId)
            if (result != TextToSpeech.SUCCESS) {
                return@withTts OffloadResponse.error(1, "speak failed: speak()=$result")
            }
            done.await(20, TimeUnit.SECONDS)
            val e = err.get()
            if (e != null) {
                OffloadResponse.error(1, e)
            } else {
                OffloadResponse.ok("spoke ${clipped.length} chars")
            }
        }
    }

    private fun withTts(block: (TextToSpeech) -> OffloadResponse): OffloadResponse {
        val out = AtomicReference(OffloadResponse.error(1, "tts timeout"))
        val latch = CountDownLatch(1)
        main.post {
            val holder = arrayOfNulls<TextToSpeech>(1)
            try {
                holder[0] = TextToSpeech(context.applicationContext) { status ->
                    val engine = holder[0]
                    try {
                        if (engine == null) {
                            out.set(OffloadResponse.error(1, "tts null engine"))
                        } else if (status != TextToSpeech.SUCCESS) {
                            out.set(OffloadResponse.error(1, "tts init failed status=$status"))
                        } else {
                            out.set(block(engine))
                        }
                    } catch (e: Exception) {
                        out.set(OffloadResponse.error(1, "tts error: ${e.message}"))
                    } finally {
                        try {
                            engine?.shutdown()
                        } catch (_: Throwable) {
                        }
                        latch.countDown()
                    }
                }
            } catch (e: Exception) {
                out.set(OffloadResponse.error(1, "tts create failed: ${e.message}"))
                latch.countDown()
            }
        }
        latch.await(25, TimeUnit.SECONDS)
        return out.get()
    }

    companion object {
        private const val MAX_CHARS = 2000
    }
}
