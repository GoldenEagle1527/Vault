package com.vault.vault.offload.handlers

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.os.Build
import com.vault.vault.offload.OffloadHandler
import com.vault.vault.offload.OffloadRequest
import com.vault.vault.offload.OffloadResponse

class NotificationHandler(private val context: Context) : OffloadHandler {
    override fun handle(req: OffloadRequest): OffloadResponse {
        val sub = req.argv.getOrNull(1) ?: "smoke"
        return when (sub) {
            "smoke" -> post(
                title = "Vault offload smoke",
                body = "notification smoke ok",
            )
            "post" -> {
                val title = req.argv.getOrNull(2) ?: "Vault"
                val body = req.argv.drop(3).joinToString(" ").ifEmpty { "notification" }
                post(title, body)
            }
            else -> OffloadResponse.unknown("notification: unknown subcommand '$sub'")
        }
    }

    private fun post(title: String, body: String): OffloadResponse {
        return try {
            ensureChannel()
            val mgr = context.getSystemService(NotificationManager::class.java)
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            val pending = PendingIntent.getActivity(
                context,
                0,
                launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val notification = Notification.Builder(context, CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(body)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentIntent(pending)
                .setAutoCancel(true)
                .build()
            val id = (System.currentTimeMillis() and 0x7fffffff).toInt()
            mgr.notify(id, notification)
            OffloadResponse.ok("notification posted")
        } catch (e: Exception) {
            OffloadResponse.error(1, "notification failed: ${e.message}")
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = context.getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Vault Offload",
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply {
            description = "Guest vault-notification / smoke tests"
        }
        mgr.createNotificationChannel(channel)
    }

    companion object {
        const val CHANNEL_ID = "vault_offload"
    }
}
