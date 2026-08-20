package com.vault.vault

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Keeps the process alive while sandbox workspaces, dev servers, or agent jobs run.
 */
class WorkspaceForegroundService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        ensureChannel()
        acquireWakeLock()
        promoteForeground(DEFAULT_TITLE, DEFAULT_TEXT)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP_SITE) {
            ProotPlugin.notifyKeepAliveAction(ACTION_STOP_SITE_DART)
            val launch = packageManager.getLaunchIntentForPackage(packageName)
            if (launch != null) {
                launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                startActivity(launch)
            }
            return START_STICKY
        }
        val title = intent?.getStringExtra(EXTRA_TITLE)
        val text = intent?.getStringExtra(EXTRA_TEXT)
        val showStop = intent?.getBooleanExtra(EXTRA_SHOW_STOP_SITE, false) == true
        if (title != null || text != null || intent?.hasExtra(EXTRA_SHOW_STOP_SITE) == true) {
            promoteForeground(
                title ?: DEFAULT_TITLE,
                text ?: DEFAULT_TEXT,
                showStopSite = showStop,
            )
        }
        return START_STICKY
    }

    override fun onDestroy() {
        isRunning = false
        releaseWakeLock()
        super.onDestroy()
    }

    private fun promoteForeground(
        title: String,
        text: String,
        showStopSite: Boolean = false,
    ) {
        val notification = buildNotification(title, text, showStopSite)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(
        title: String,
        text: String,
        showStopSite: Boolean,
    ): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val pending = PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentIntent(pending)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
        if (showStopSite) {
            val stopIntent = Intent(this, WorkspaceForegroundService::class.java).apply {
                action = ACTION_STOP_SITE
            }
            val stopPending = PendingIntent.getService(
                this,
                1,
                stopIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            builder.addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(this, android.R.drawable.ic_media_pause),
                    "停止站点",
                    stopPending,
                ).build(),
            )
        }
        return builder.build()
    }

    private fun acquireWakeLock() {
        releaseWakeLock()
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "Vault::WorkspaceForeground",
        ).apply {
            setReferenceCounted(false)
            acquire(WAKE_LOCK_TIMEOUT_MS)
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let {
            if (it.isHeld) it.release()
        }
        wakeLock = null
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Vault 工作区",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "沙箱工作区、站点与 Agent 任务在后台运行时显示"
            setShowBadge(false)
        }
        mgr.createNotificationChannel(channel)
    }

    companion object {
        const val ACTION_STOP_SITE = "com.vault.vault.STOP_SITE"
        const val ACTION_STOP_SITE_DART = "stopSite"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        const val EXTRA_SHOW_STOP_SITE = "showStopSite"

        private const val CHANNEL_ID = "vault_workspace"
        private const val NOTIFICATION_ID = 7301
        private const val WAKE_LOCK_TIMEOUT_MS = 10L * 60L * 60L * 1000L

        private const val DEFAULT_TITLE = "Vault 工作区运行中"
        private const val DEFAULT_TEXT = "沙箱与 Agent 任务在后台继续运行，点按返回应用。"

        @Volatile
        var isRunning: Boolean = false
            private set
    }
}
