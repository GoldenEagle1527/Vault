package com.vault.vault.offload

import android.content.Context
import android.util.Log
import com.vault.vault.offload.handlers.A11yHandler
import com.vault.vault.offload.handlers.CalendarHandler
import com.vault.vault.offload.handlers.ClipboardHandler
import com.vault.vault.offload.handlers.ContactsHandler
import com.vault.vault.offload.handlers.DeviceHandler
import com.vault.vault.offload.handlers.HostFilesHandler
import com.vault.vault.offload.handlers.LocationHandler
import com.vault.vault.offload.handlers.NotificationHandler
import com.vault.vault.offload.handlers.OpenHandler
import com.vault.vault.offload.handlers.PhotosHandler
import com.vault.vault.offload.handlers.ShizukuHandler
import com.vault.vault.offload.handlers.SpeakHandler
import com.vault.vault.offload.handlers.SpeechHandler
import com.vault.vault.offload.handlers.VaultConfigHandler
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * Localhost TCP bridge for guest → host offload (stock proot shares host network).
 *
 * Protocol: one JSON request line → one JSON response line.
 * Also accepts a minimal HTTP POST (for busybox wget) with the same JSON body.
 */
class OffloadServer(
    private val context: Context,
    private val gate: OffloadGate,
) {
    private val running = AtomicBoolean(false)
    private val portRef = AtomicInteger(0)
    private var serverSocket: ServerSocket? = null
    private var acceptThread: Thread? = null
    private val pool = Executors.newCachedThreadPool()

    private val handlers: Map<String, OffloadHandler> by lazy {
        val clipboard = ClipboardHandler(context)
        val device = DeviceHandler()
        val open = OpenHandler(context)
        val notification = NotificationHandler(context)
        val calendar = CalendarHandler(context)
        val contacts = ContactsHandler(context)
        val photos = PhotosHandler(context)
        val location = LocationHandler(context)
        val hostFiles = HostFilesHandler(context)
        val vaultConfig = VaultConfigHandler()
        val speak = SpeakHandler(context)
        val speech = SpeechHandler(context)
        val a11y = A11yHandler(context)
        val shizuku = ShizukuHandler(context)
        mapOf(
            // Wave1
            "clipboard" to clipboard,
            "vault-clipboard" to clipboard,
            "device" to device,
            "vault-device" to device,
            "device_info" to device,
            "open" to open,
            "vault-open" to open,
            "open_url" to open,
            "notification" to notification,
            "vault-notification" to notification,
            // Wave2
            "calendar" to calendar,
            "vault-calendar" to calendar,
            "contacts" to contacts,
            "vault-contacts" to contacts,
            "photos" to photos,
            "vault-photos" to photos,
            "location" to location,
            "vault-location" to location,
            // Wave3
            "host-files" to hostFiles,
            "host_files" to hostFiles,
            "vault-host-files" to hostFiles,
            "config" to vaultConfig,
            "vault_config" to vaultConfig,
            "vault-config" to vaultConfig,
            "speak" to speak,
            "vault-speak" to speak,
            "speech" to speech,
            "vault-speech" to speech,
            // Wave4 (Android integrations; high-risk — Dart default NOT_ALLOWED)
            "a11y" to a11y,
            "vault-a11y" to a11y,
            "shizuku" to shizuku,
            "vault-shizuku" to shizuku,
        )
    }

    val port: Int get() = portRef.get()
    val isRunning: Boolean get() = running.get()

    @Synchronized
    fun start(): Int {
        if (running.get() && serverSocket?.isClosed == false) {
            return portRef.get()
        }
        val ss = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
        serverSocket = ss
        portRef.set(ss.localPort)
        running.set(true)
        acceptThread = Thread({
            while (running.get()) {
                try {
                    val client = ss.accept()
                    pool.execute { handleClient(client) }
                } catch (_: Throwable) {
                    if (!running.get()) break
                }
            }
        }, "vault-offload-accept").apply {
            isDaemon = true
            start()
        }
        Log.i(TAG, "OffloadServer listening on 127.0.0.1:${portRef.get()}")
        return portRef.get()
    }

    @Synchronized
    fun stop() {
        running.set(false)
        try {
            serverSocket?.close()
        } catch (_: Throwable) {
        }
        serverSocket = null
        portRef.set(0)
        acceptThread = null
        Log.i(TAG, "OffloadServer stopped")
    }

    private fun handleClient(socket: Socket) {
        socket.soTimeout = 15_000
        try {
            socket.use { sock ->
                val reader = BufferedReader(InputStreamReader(sock.getInputStream(), Charsets.UTF_8))
                val writer = BufferedWriter(OutputStreamWriter(sock.getOutputStream(), Charsets.UTF_8))
                val first = reader.readLine() ?: return
                val (body, http) = if (first.startsWith("{")) {
                    first to false
                } else if (first.startsWith("POST", ignoreCase = true) ||
                    first.startsWith("GET", ignoreCase = true)
                ) {
                    readHttpBody(first, reader) to true
                } else {
                    // Treat entire first line as JSON anyway
                    first to false
                }
                if (body.isNullOrBlank()) {
                    writeResponse(writer, OffloadResponse.error(1, "empty request"), http)
                    return
                }
                val response = dispatch(body)
                writeResponse(writer, response, http)
            }
        } catch (e: Exception) {
            Log.w(TAG, "client error: ${e.message}")
        }
    }

    private fun readHttpBody(requestLine: String, reader: BufferedReader): String? {
        var contentLength = 0
        while (true) {
            val line = reader.readLine() ?: break
            if (line.isEmpty()) break
            val lower = line.lowercase()
            if (lower.startsWith("content-length:")) {
                contentLength = lower.substringAfter(':').trim().toIntOrNull() ?: 0
            }
        }
        if (contentLength <= 0) {
            // Some clients send body without length; try one more line.
            return reader.readLine()
        }
        val buf = CharArray(contentLength)
        var off = 0
        while (off < contentLength) {
            val n = reader.read(buf, off, contentLength - off)
            if (n < 0) break
            off += n
        }
        return String(buf, 0, off)
    }

    private fun writeResponse(writer: BufferedWriter, response: OffloadResponse, http: Boolean) {
        val json = response.toJsonLine()
        if (http) {
            val bytes = json.toByteArray(Charsets.UTF_8)
            writer.write("HTTP/1.1 200 OK\r\n")
            writer.write("Content-Type: application/json; charset=utf-8\r\n")
            writer.write("Content-Length: ${bytes.size}\r\n")
            writer.write("Connection: close\r\n")
            writer.write("\r\n")
            writer.write(json)
        } else {
            writer.write(json)
            writer.write("\n")
        }
        writer.flush()
    }

    fun dispatch(rawJson: String): OffloadResponse {
        val req = try {
            OffloadRequest.fromJson(rawJson)
        } catch (e: Exception) {
            return OffloadResponse.error(1, "bad json: ${e.message}")
        }
        if (req.argv.isEmpty()) {
            return OffloadResponse.unknown("empty argv")
        }
        val basename = req.argv[0].substringAfterLast('/').substringAfterLast('\\')
        val capability = capabilityForBasename(basename)
        if (!gate.check(capability, req.sessionId)) {
            return OffloadResponse.permissionDenied()
        }
        val handler = handlers[basename] ?: handlers[capability]
            ?: return OffloadResponse.unknown("unknown command: $basename")
        return try {
            handler.handle(req)
        } catch (e: Exception) {
            OffloadResponse.error(1, "handler error: ${e.message}")
        }
    }

    companion object {
        private const val TAG = "VaultOffload"

        /**
         * Map CLI basename → PermissionRegistry id (same intent as Dart OffloadGate).
         *
         * CRITICAL: do **not** use `removePrefix("vault-")` alone —
         * `vault-config` would become `config` (wrong; registry id is `vault_config`),
         * and `vault-host-files` would become `host-files` (wrong; id is `host_files`).
         */
        fun capabilityForBasename(basename: String): String {
            return when (basename) {
                // Wave1
                "clipboard", "vault-clipboard" -> "clipboard"
                "device", "vault-device", "device_info" -> "device_info"
                "open", "vault-open", "open_url" -> "open_url"
                "notification", "vault-notification" -> "notification"
                // Wave2
                "calendar", "vault-calendar" -> "calendar"
                "contacts", "vault-contacts" -> "contacts"
                "photos", "vault-photos" -> "photos"
                "location", "vault-location" -> "location"
                // Wave3
                "host-files", "host_files", "vault-host-files" -> "host_files"
                "config", "vault_config", "vault-config" -> "vault_config"
                "speak", "vault-speak" -> "speak"
                "speech", "vault-speech" -> "speech"
                // Wave4
                "a11y", "vault-a11y" -> "a11y"
                "shizuku", "vault-shizuku" -> "shizuku"
                else -> basename.removePrefix("vault-").replace('-', '_')
            }
        }
    }
}
