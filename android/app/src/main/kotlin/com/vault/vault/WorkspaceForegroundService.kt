package com.vault.vault

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * Keeps the process alive while sandbox workspaces are running (apk / long jobs).
 */
class WorkspaceForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val pending = PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Vault 工作区运行中")
            .setContentText("沙箱终端仍在后台活动，点按返回应用。")
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentIntent(pending)
            .setOngoing(true)
            .build()
        startForeground(NOTIFICATION_ID, notification)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return START_STICKY
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Vault 工作区",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "有活跃沙箱工作区时显示"
        }
        mgr.createNotificationChannel(channel)
    }

    companion object {
        private const val CHANNEL_ID = "vault_workspace"
        private const val NOTIFICATION_ID = 7301
    }
}
