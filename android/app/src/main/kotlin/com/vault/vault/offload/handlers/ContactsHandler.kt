package com.vault.vault.offload.handlers

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.provider.ContactsContract
import com.vault.vault.offload.OffloadHandler
import com.vault.vault.offload.OffloadRequest
import com.vault.vault.offload.OffloadResponse
import org.json.JSONArray
import org.json.JSONObject

class ContactsHandler(private val context: Context) : OffloadHandler {
    override fun handle(req: OffloadRequest): OffloadResponse {
        val sub = req.argv.getOrNull(1) ?: "smoke"
        return when (sub) {
            "smoke" -> smoke()
            "list" -> list(parseLimit(req.argv.getOrNull(2)))
            else -> OffloadResponse.unknown("contacts: unknown subcommand '$sub'")
        }
    }

    private fun smoke(): OffloadResponse {
        if (!hasReadPermission()) {
            return permissionNeeded()
        }
        return try {
            val n = listContacts(1).length()
            OffloadResponse.ok("contacts smoke ok (contacts_sampled=$n)")
        } catch (e: SecurityException) {
            permissionNeeded(e.message)
        } catch (e: Exception) {
            OffloadResponse.error(1, "contacts smoke failed: ${e.message}")
        }
    }

    private fun list(limit: Int): OffloadResponse {
        if (!hasReadPermission()) {
            return permissionNeeded()
        }
        return try {
            val arr = listContacts(limit)
            OffloadResponse.ok(arr.toString())
        } catch (e: SecurityException) {
            permissionNeeded(e.message)
        } catch (e: Exception) {
            OffloadResponse.error(1, "contacts list failed: ${e.message}")
        }
    }

    private fun listContacts(limit: Int): JSONArray {
        val arr = JSONArray()
        val projection = arrayOf(
            ContactsContract.Contacts._ID,
            ContactsContract.Contacts.DISPLAY_NAME_PRIMARY,
            ContactsContract.Contacts.HAS_PHONE_NUMBER,
        )
        context.contentResolver.query(
            ContactsContract.Contacts.CONTENT_URI,
            projection,
            null,
            null,
            "${ContactsContract.Contacts.DISPLAY_NAME_PRIMARY} ASC",
        )?.use { cursor ->
            val idIdx = cursor.getColumnIndex(ContactsContract.Contacts._ID)
            val nameIdx = cursor.getColumnIndex(ContactsContract.Contacts.DISPLAY_NAME_PRIMARY)
            val phoneIdx = cursor.getColumnIndex(ContactsContract.Contacts.HAS_PHONE_NUMBER)
            var count = 0
            while (cursor.moveToNext() && count < limit) {
                val id = if (idIdx >= 0) cursor.getLong(idIdx) else -1L
                val name = if (nameIdx >= 0) cursor.getString(nameIdx) ?: "" else ""
                val hasPhone = if (phoneIdx >= 0) cursor.getInt(phoneIdx) > 0 else false
                arr.put(
                    JSONObject()
                        .put("id", if (id >= 0) id else JSONObject.NULL)
                        .put("displayName", name)
                        .put("hasPhoneNumber", hasPhone),
                )
                count++
            }
        }
        return arr
    }

    private fun hasReadPermission(): Boolean =
        context.checkSelfPermission(Manifest.permission.READ_CONTACTS) ==
            PackageManager.PERMISSION_GRANTED

    private fun permissionNeeded(detail: String? = null): OffloadResponse {
        val msg = JSONObject()
            .put("error", "os_permission_required")
            .put("permission", "READ_CONTACTS")
            .put(
                "message",
                "Grant contacts permission in Android Settings for Vault" +
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
