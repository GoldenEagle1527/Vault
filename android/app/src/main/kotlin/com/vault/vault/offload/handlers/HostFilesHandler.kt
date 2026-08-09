package com.vault.vault.offload.handlers

import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import com.vault.vault.offload.OffloadHandler
import com.vault.vault.offload.OffloadRequest
import com.vault.vault.offload.OffloadResponse
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Scoped host filesystem access — app-specific dirs only (+ optional MediaStore
 * Downloads metadata). Never exposes arbitrary SD card / full device FS.
 */
class HostFilesHandler(private val context: Context) : OffloadHandler {
    override fun handle(req: OffloadRequest): OffloadResponse {
        val sub = req.argv.getOrNull(1) ?: "smoke"
        return when (sub) {
            "smoke" -> smoke()
            "list" -> list(req.argv.getOrNull(2))
            else -> OffloadResponse.unknown("host_files: unknown subcommand '$sub'")
        }
    }

    private fun smoke(): OffloadResponse {
        return try {
            val root = primaryRoot()
            if (!root.exists()) root.mkdirs()
            val file = File(root, SMOKE_NAME)
            val marker = "vault-host-files-smoke"
            file.writeText(marker, Charsets.UTF_8)
            val got = file.readText(Charsets.UTF_8)
            if (got != marker) {
                return OffloadResponse.error(1, "host_files smoke failed: read mismatch")
            }
            val body = JSONObject()
                .put("ok", true)
                .put("path", file.absolutePath)
                .put("root", root.absolutePath)
                .put("bytes", marker.length)
            OffloadResponse.ok(body.toString())
        } catch (e: Exception) {
            OffloadResponse.error(1, "host_files smoke failed: ${e.message}")
        }
    }

    private fun list(pathArg: String?): OffloadResponse {
        val raw = pathArg?.trim().orEmpty()
        if (raw.equals("downloads", ignoreCase = true) ||
            raw.equals("mediastore:downloads", ignoreCase = true)
        ) {
            return listMediaStoreDownloads()
        }
        val dir = resolveAllowed(if (raw.isEmpty()) null else raw)
            ?: return OffloadResponse.error(
                1,
                JSONObject()
                    .put("error", "path_not_allowed")
                    .put("message", "Path outside allowed app-specific roots or traversal rejected")
                    .put("path", raw)
                    .toString(),
            )
        if (!dir.exists()) {
            return OffloadResponse.error(1, "host_files list: not found: ${dir.absolutePath}")
        }
        if (!dir.isDirectory) {
            return OffloadResponse.error(1, "host_files list: not a directory: ${dir.absolutePath}")
        }
        return try {
            val arr = JSONArray()
            val children = dir.listFiles()?.sortedBy { it.name.lowercase() } ?: emptyList()
            for (child in children.take(MAX_ENTRIES)) {
                arr.put(
                    JSONObject()
                        .put("name", child.name)
                        .put("path", child.absolutePath)
                        .put("isDirectory", child.isDirectory)
                        .put("size", if (child.isFile) child.length() else JSONObject.NULL),
                )
            }
            val body = JSONObject()
                .put("root", dir.absolutePath)
                .put("entries", arr)
                .put("count", arr.length())
            OffloadResponse.ok(body.toString())
        } catch (e: Exception) {
            OffloadResponse.error(1, "host_files list failed: ${e.message}")
        }
    }

    private fun listMediaStoreDownloads(): OffloadResponse {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            // Pre-Q: fall back to app-specific Downloads dir (still scoped).
            val appDl = context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
            return if (appDl != null) {
                list(appDl.absolutePath)
            } else {
                OffloadResponse.error(
                    1,
                    "host_files downloads: MediaStore.Downloads requires API 29+",
                )
            }
        }
        return try {
            val arr = JSONArray()
            val projection = arrayOf(
                MediaStore.Downloads._ID,
                MediaStore.Downloads.DISPLAY_NAME,
                MediaStore.Downloads.SIZE,
                MediaStore.Downloads.MIME_TYPE,
            )
            context.contentResolver.query(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                projection,
                null,
                null,
                "${MediaStore.Downloads.DATE_ADDED} DESC",
            )?.use { cursor ->
                val idIdx = cursor.getColumnIndex(MediaStore.Downloads._ID)
                val nameIdx = cursor.getColumnIndex(MediaStore.Downloads.DISPLAY_NAME)
                val sizeIdx = cursor.getColumnIndex(MediaStore.Downloads.SIZE)
                val mimeIdx = cursor.getColumnIndex(MediaStore.Downloads.MIME_TYPE)
                var n = 0
                while (cursor.moveToNext() && n < MAX_ENTRIES) {
                    arr.put(
                        JSONObject()
                            .put("id", if (idIdx >= 0) cursor.getLong(idIdx) else JSONObject.NULL)
                            .put("name", if (nameIdx >= 0) cursor.getString(nameIdx) ?: "" else "")
                            .put("size", if (sizeIdx >= 0) cursor.getLong(sizeIdx) else JSONObject.NULL)
                            .put("mimeType", if (mimeIdx >= 0) cursor.getString(mimeIdx) ?: "" else "")
                            .put("source", "mediastore:downloads"),
                    )
                    n++
                }
            }
            val body = JSONObject()
                .put("root", "mediastore:downloads")
                .put("entries", arr)
                .put("count", arr.length())
                .put("note", "Metadata only; not a raw filesystem path")
            OffloadResponse.ok(body.toString())
        } catch (e: SecurityException) {
            OffloadResponse.error(
                1,
                JSONObject()
                    .put("error", "os_permission_required")
                    .put("permission", "READ_MEDIA / READ_EXTERNAL_STORAGE")
                    .put("message", "MediaStore Downloads query denied: ${e.message}")
                    .toString(),
            )
        } catch (e: Exception) {
            OffloadResponse.error(1, "host_files downloads list failed: ${e.message}")
        }
    }

    /** Resolve [path] under allowed roots; reject traversal / escape. */
    private fun resolveAllowed(path: String?): File? {
        val roots = allowedRoots()
        if (roots.isEmpty()) return null
        if (path.isNullOrBlank() || path == "." || path == "/") {
            return roots.first()
        }
        // Reject null bytes and obvious escape attempts before resolve.
        if (path.contains('\u0000')) return null

        val primary = roots.first()
        val candidate = try {
            val raw = File(path)
            if (raw.isAbsolute) {
                raw.canonicalFile
            } else {
                File(primary, path).canonicalFile
            }
        } catch (_: Exception) {
            return null
        }

        return if (roots.any { isUnderRoot(candidate, it) }) candidate else null
    }

    private fun isUnderRoot(file: File, root: File): Boolean {
        val f = file.absolutePath
        val r = root.absolutePath
        return f == r || f.startsWith(r + File.separator)
    }

    private fun allowedRoots(): List<File> {
        val out = linkedSetOf<File>()
        try {
            context.getExternalFilesDir(null)?.canonicalFile?.let { out.add(it) }
        } catch (_: Exception) {
        }
        try {
            out.add(context.filesDir.canonicalFile)
        } catch (_: Exception) {
        }
        try {
            context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
                ?.canonicalFile
                ?.let { out.add(it) }
        } catch (_: Exception) {
        }
        return out.toList()
    }

    private fun primaryRoot(): File =
        context.getExternalFilesDir(null) ?: context.filesDir

    companion object {
        private const val SMOKE_NAME = "vault-host-files-smoke.txt"
        private const val MAX_ENTRIES = 500
    }
}
