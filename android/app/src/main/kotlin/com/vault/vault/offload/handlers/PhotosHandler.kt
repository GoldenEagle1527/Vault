package com.vault.vault.offload.handlers

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.provider.MediaStore
import com.vault.vault.offload.OffloadHandler
import com.vault.vault.offload.OffloadRequest
import com.vault.vault.offload.OffloadResponse
import org.json.JSONArray
import org.json.JSONObject

class PhotosHandler(private val context: Context) : OffloadHandler {
    override fun handle(req: OffloadRequest): OffloadResponse {
        val sub = req.argv.getOrNull(1) ?: "smoke"
        return when (sub) {
            "smoke" -> smoke()
            "list" -> list(parseLimit(req.argv.getOrNull(2)))
            else -> OffloadResponse.unknown("photos: unknown subcommand '$sub'")
        }
    }

    private fun smoke(): OffloadResponse {
        if (!hasReadPermission()) {
            return permissionNeeded()
        }
        return try {
            val count = countImages()
            OffloadResponse.ok("photos smoke ok (image_count=$count)")
        } catch (e: SecurityException) {
            permissionNeeded(e.message)
        } catch (e: Exception) {
            OffloadResponse.error(1, "photos smoke failed: ${e.message}")
        }
    }

    private fun list(limit: Int): OffloadResponse {
        if (!hasReadPermission()) {
            return permissionNeeded()
        }
        return try {
            val arr = listImages(limit)
            OffloadResponse.ok(arr.toString())
        } catch (e: SecurityException) {
            permissionNeeded(e.message)
        } catch (e: Exception) {
            OffloadResponse.error(1, "photos list failed: ${e.message}")
        }
    }

    private fun countImages(): Int {
        context.contentResolver.query(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            arrayOf(MediaStore.Images.Media._ID),
            null,
            null,
            null,
        )?.use { cursor ->
            return cursor.count
        }
        return 0
    }

    private fun listImages(limit: Int): JSONArray {
        val arr = JSONArray()
        val projection = arrayOf(
            MediaStore.Images.Media._ID,
            MediaStore.Images.Media.DISPLAY_NAME,
            MediaStore.Images.Media.MIME_TYPE,
            MediaStore.Images.Media.DATE_ADDED,
            MediaStore.Images.Media.SIZE,
            MediaStore.Images.Media.WIDTH,
            MediaStore.Images.Media.HEIGHT,
        )
        val sort = "${MediaStore.Images.Media.DATE_ADDED} DESC"
        context.contentResolver.query(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            projection,
            null,
            null,
            sort,
        )?.use { cursor ->
            val idIdx = cursor.getColumnIndex(MediaStore.Images.Media._ID)
            val nameIdx = cursor.getColumnIndex(MediaStore.Images.Media.DISPLAY_NAME)
            val mimeIdx = cursor.getColumnIndex(MediaStore.Images.Media.MIME_TYPE)
            val dateIdx = cursor.getColumnIndex(MediaStore.Images.Media.DATE_ADDED)
            val sizeIdx = cursor.getColumnIndex(MediaStore.Images.Media.SIZE)
            val wIdx = cursor.getColumnIndex(MediaStore.Images.Media.WIDTH)
            val hIdx = cursor.getColumnIndex(MediaStore.Images.Media.HEIGHT)
            var count = 0
            while (cursor.moveToNext() && count < limit) {
                val id = if (idIdx >= 0) cursor.getLong(idIdx) else -1L
                arr.put(
                    JSONObject()
                        .put("id", if (id >= 0) id else JSONObject.NULL)
                        .put("displayName", if (nameIdx >= 0) cursor.getString(nameIdx) ?: "" else "")
                        .put("mimeType", if (mimeIdx >= 0) cursor.getString(mimeIdx) ?: "" else "")
                        .put("dateAdded", if (dateIdx >= 0) cursor.getLong(dateIdx) else JSONObject.NULL)
                        .put("size", if (sizeIdx >= 0) cursor.getLong(sizeIdx) else JSONObject.NULL)
                        .put("width", if (wIdx >= 0) cursor.getInt(wIdx) else JSONObject.NULL)
                        .put("height", if (hIdx >= 0) cursor.getInt(hIdx) else JSONObject.NULL),
                )
                count++
            }
        }
        return arr
    }

    private fun hasReadPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.checkSelfPermission(Manifest.permission.READ_MEDIA_IMAGES) ==
                PackageManager.PERMISSION_GRANTED
        } else {
            context.checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        }
    }

    private fun permissionNeeded(detail: String? = null): OffloadResponse {
        val perm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            "READ_MEDIA_IMAGES"
        } else {
            "READ_EXTERNAL_STORAGE"
        }
        val msg = JSONObject()
            .put("error", "os_permission_required")
            .put("permission", perm)
            .put(
                "message",
                "Grant photos/media permission in Android Settings for Vault" +
                    (if (detail.isNullOrBlank()) "" else ": $detail"),
            )
            .toString()
        return OffloadResponse.error(1, msg)
    }

    private fun parseLimit(raw: String?): Int {
        val n = raw?.toIntOrNull() ?: DEFAULT_LIMIT
        return n.coerceIn(1, MAX_LIMIT)
    }

    companion object {
        private const val DEFAULT_LIMIT = 20
        private const val MAX_LIMIT = 200
    }
}
