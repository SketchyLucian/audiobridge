package com.audiobridge.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log

private const val NOTIFICATION_CHANNEL_ID = "audio_bridge_active_stream"
private const val NOTIFICATION_ID = 47885

class AudioRelayForegroundService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val engine = AudioEngineHolder.receiverEngine(applicationContext)
        val startingStream = intent?.action == ACTION_START_STREAM
        if (!startingStream && !(intent == null && engine.isStreamActive())) {
            stopSelf(startId)
            return START_NOT_STICKY
        }

        startForegroundForCurrentRole()
        acquireWakeLock()
        updateWifiLock()
        logLowPowerStandbyRisk()
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        releaseWifiLock()
        wakeLock?.let {
            if (it.isHeld) {
                it.release()
            }
        }
        wakeLock = null
        super.onDestroy()
    }

    @Suppress("DEPRECATION")
    private fun updateWifiLock() {
        if (!AudioEngineHolder.receiverEngine(applicationContext).needsWifiLockForStream()) {
            releaseWifiLock()
            return
        }
        if (wifiLock?.isHeld == true) {
            return
        }

        val wifiManager = applicationContext
            .getSystemService(WIFI_SERVICE) as? WifiManager ?: return
        try {
            wifiLock = wifiManager.createWifiLock(
                WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                "AudioBridge:NetworkStream"
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (error: RuntimeException) {
            wifiLock = null
            Log.w(LOG_TAG, "Unable to keep Wi-Fi awake for the active stream", error)
        }
    }

    private fun releaseWifiLock() {
        wifiLock?.let {
            if (it.isHeld) {
                try {
                    it.release()
                } catch (error: RuntimeException) {
                    Log.w(LOG_TAG, "Unable to release the stream Wi-Fi lock", error)
                }
            }
        }
        wifiLock = null
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }

        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            "AudioBridge active stream",
            NotificationManager.IMPORTANCE_DEFAULT
        ).apply {
            description = "Keeps AudioBridge playback running in the background."
            setSound(null, null)
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) {
            return
        }

        val powerManager = getSystemService(PowerManager::class.java)
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "AudioBridge:ReceiverStream"
        ).apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun buildNotification(): Notification {
        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntentFlags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        val pendingIntent = PendingIntent.getActivity(this, 0, openIntent, pendingIntentFlags)

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }

        return builder
            .setContentTitle("AudioBridge is running")
            .setContentText(notificationText())
            .setSmallIcon(R.drawable.ic_stat_audiobridge)
            .setContentIntent(pendingIntent)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(Notification.PRIORITY_DEFAULT)
            .setShowWhen(false)
            .apply {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
                }
            }
            .build()
    }

    private fun startForegroundForCurrentRole() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val roleType = if (
                AudioEngineHolder.receiverEngine(applicationContext).needsMicrophonePermissionForStream()
            ) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            } else {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            }
            val serviceType = roleType or ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            startForeground(NOTIFICATION_ID, notification, serviceType)
            return
        }

        startForeground(NOTIFICATION_ID, notification)
    }

    private fun notificationText(): String {
        return if (hasLowPowerStandbyRisk()) {
            "Low Power Standby can pause screen-off network audio."
        } else {
            "Audio streaming continues in the background."
        }
    }

    private fun logLowPowerStandbyRisk() {
        if (hasLowPowerStandbyRisk()) {
            Log.w(
                LOG_TAG,
                "Low Power Standby is enabled and may block network access while the screen is off"
            )
        }
    }

    private fun hasLowPowerStandbyRisk(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return false
        }

        val powerManager = getSystemService(PowerManager::class.java)
        return try {
            if (!powerManager.isLowPowerStandbyEnabled) {
                false
            } else {
                Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE ||
                    !powerManager.isExemptFromLowPowerStandby
            }
        } catch (error: RuntimeException) {
            Log.w(LOG_TAG, "Unable to read Low Power Standby state", error)
            false
        }
    }

    companion object {
        const val ACTION_START_STREAM = "com.audiobridge.app.action.START_STREAM"
        private const val LOG_TAG = "AudioBridgeService"
    }
}
