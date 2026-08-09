package com.vault.vault.offload.handlers

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.provider.CalendarContract
import com.vault.vault.offload.OffloadHandler
import com.vault.vault.offload.OffloadRequest
import com.vault.vault.offload.OffloadResponse
import org.json.JSONArray
import org.json.JSONObject

class CalendarHandler(private val context: Context) : OffloadHandler {
    override fun handle(req: OffloadRequest): OffloadResponse {
        val sub = req.argv.getOrNull(1) ?: "smoke"
        return when (sub) {
            "smoke" -> smoke()
            "list" -> list(parseLimit(req.argv.getOrNull(2)))
            else -> OffloadResponse.unknown("calendar: unknown subcommand '$sub'")
        }
    }

    private fun smoke(): OffloadResponse {
        if (!hasReadPermission()) {
            return permissionNeeded()
        }
        return try {
            val n = listEvents(1).length()
            OffloadResponse.ok("calendar smoke ok (events_sampled=$n)")
        } catch (e: SecurityException) {
            permissionNeeded(e.message)
        } catch (e: Exception) {
            OffloadResponse.error(1, "calendar smoke failed: ${e.message}")
        }
    }

    private fun list(limit: Int): OffloadResponse {
        if (!hasReadPermission()) {
            return permissionNeeded()
        }
        return try {
            val arr = listEvents(limit)
            OffloadResponse.ok(arr.toString())
        } catch (e: SecurityException) {
            permissionNeeded(e.message)
        } catch (e: Exception) {
            OffloadResponse.error(1, "calendar list failed: ${e.message}")
        }
    }

    private fun listEvents(limit: Int): JSONArray {
        val arr = JSONArray()
        val projection = arrayOf(
            CalendarContract.Events._ID,
            CalendarContract.Events.TITLE,
            CalendarContract.Events.DTSTART,
            CalendarContract.Events.DTEND,
            CalendarContract.Events.ALL_DAY,
            CalendarContract.Events.EVENT_LOCATION,
            CalendarContract.Events.CALENDAR_DISPLAY_NAME,
        )
        context.contentResolver.query(
            CalendarContract.Events.CONTENT_URI,
            projection,
            null,
            null,
            "${CalendarContract.Events.DTSTART} DESC",
        )?.use { cursor ->
            val idIdx = cursor.getColumnIndex(CalendarContract.Events._ID)
            val titleIdx = cursor.getColumnIndex(CalendarContract.Events.TITLE)
            val startIdx = cursor.getColumnIndex(CalendarContract.Events.DTSTART)
            val endIdx = cursor.getColumnIndex(CalendarContract.Events.DTEND)
            val allDayIdx = cursor.getColumnIndex(CalendarContract.Events.ALL_DAY)
            val locIdx = cursor.getColumnIndex(CalendarContract.Events.EVENT_LOCATION)
            val calIdx = cursor.getColumnIndex(CalendarContract.Events.CALENDAR_DISPLAY_NAME)
            var count = 0
            while (cursor.moveToNext() && count < limit) {
                arr.put(
                    JSONObject()
                        .put("id", if (idIdx >= 0) cursor.getLong(idIdx) else JSONObject.NULL)
                        .put("title", if (titleIdx >= 0) cursor.getString(titleIdx) ?: "" else "")
                        .put("dtStart", if (startIdx >= 0) cursor.getLong(startIdx) else JSONObject.NULL)
                        .put("dtEnd", if (endIdx >= 0) cursor.getLong(endIdx) else JSONObject.NULL)
                        .put("allDay", if (allDayIdx >= 0) cursor.getInt(allDayIdx) == 1 else false)
                        .put("location", if (locIdx >= 0) cursor.getString(locIdx) ?: "" else "")
                        .put("calendar", if (calIdx >= 0) cursor.getString(calIdx) ?: "" else ""),
                )
                count++
            }
        }
        return arr
    }

    private fun hasReadPermission(): Boolean =
        context.checkSelfPermission(Manifest.permission.READ_CALENDAR) ==
            PackageManager.PERMISSION_GRANTED

    private fun permissionNeeded(detail: String? = null): OffloadResponse {
        val msg = JSONObject()
            .put("error", "os_permission_required")
            .put("permission", "READ_CALENDAR")
            .put(
                "message",
                "Grant calendar permission in Android Settings for Vault" +
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
