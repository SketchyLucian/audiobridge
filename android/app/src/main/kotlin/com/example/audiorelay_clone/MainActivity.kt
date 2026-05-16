package com.example.audiorelay_clone

import android.Manifest
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.usb.UsbManager
import android.os.Build
import android.util.Log
import android.widget.Toast
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.Collections

class MainActivity : FlutterActivity() {
    private val audioEngine by lazy { AudioEngineHolder.receiverEngine(applicationContext) }
    private var pendingStartResult: MethodChannel.Result? = null
    private var pendingStartArguments: Any? = null
    private var usbPermissionReceiverRegistered = false
    private val usbPermissionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != USB_PERMISSION_ACTION) {
                return
            }

            val result = pendingStartResult ?: return
            val arguments = pendingStartArguments
            pendingStartResult = null
            pendingStartArguments = null

            if (intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)) {
                startStream(arguments, result)
            } else {
                result.error(
                    "usb_permission_denied",
                    "Approve the AudioBridge native USB accessory permission.",
                    null
                )
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "audio_bridge/native_engine"
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "getCapabilities" -> result.success(audioEngine.getCapabilities())

                    "getNetworkInterfaces" -> result.success(networkInterfaces())

                    "getMetrics" -> result.success(audioEngine.getMetrics())

                    "prepareReceiver" -> {
                        audioEngine.prepareReceiver(call.arguments)
                        result.success(null)
                    }

                    "prepareUsbReceiver" -> {
                        audioEngine.prepareUsbReceiver(call.arguments)
                        result.success(null)
                    }

                    "prepareUsbSender" -> {
                        audioEngine.prepareUsbSender(call.arguments)
                        result.success(null)
                    }

                    "prepareSender" -> {
                        audioEngine.prepareSender(call.arguments)
                        result.success(null)
                    }

                    "connectToSender" -> {
                        audioEngine.connectToSender(call.arguments)
                        result.success(null)
                    }

                    "startStream" -> {
                        startStreamWhenPermissionsAllowed(call.arguments, result)
                    }

                    "stopStream" -> {
                        audioEngine.stopStream()
                        stopAudioRelayService()
                        result.success(null)
                    }

                    "setVolume" -> {
                        audioEngine.setVolume(call.arguments)
                        result.success(null)
                    }

                    "setMuted" -> {
                        audioEngine.setMuted(call.arguments)
                        result.success(null)
                    }

                    "disconnect" -> {
                        audioEngine.disconnect()
                        stopAudioRelayService()
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            } catch (error: IllegalStateException) {
                result.error("audio_engine", error.message, null)
            } catch (error: IllegalArgumentException) {
                result.error("audio_engine", error.message, null)
            }
        }

        handleUsbAccessoryIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleUsbAccessoryIntent(intent)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != STREAM_PERMISSION_REQUEST_CODE) {
            return
        }

        val result = pendingStartResult ?: return
        val arguments = pendingStartArguments
        pendingStartResult = null
        pendingStartArguments = null

        if (streamPermissionsAllowed()) {
            startStreamWhenPermissionsAllowed(arguments, result)
        } else if (audioEngine.needsMicrophonePermissionForStream() && !microphoneAllowed()) {
            result.error(
                "microphone_permission_denied",
                "Allow microphone access so Android can send audio.",
                null
            )
        } else {
            result.error(
                "notification_permission_denied",
                "Allow notifications so Android can show the AudioBridge background audio notification.",
                null
            )
        }
    }

    override fun onDestroy() {
        if (usbPermissionReceiverRegistered) {
            unregisterReceiver(usbPermissionReceiver)
            usbPermissionReceiverRegistered = false
        }
        super.onDestroy()
    }

    private fun startStreamWhenPermissionsAllowed(
        arguments: Any?,
        result: MethodChannel.Result
    ) {
        if (streamPermissionsAllowed()) {
            if (requestUsbAccessoryPermissionIfNeeded(arguments, result)) {
                return
            }
            startStream(arguments, result)
            return
        }

        if (pendingStartResult != null) {
            result.error(
                "stream_permission_pending",
                "Stream permissions are already being requested.",
                null
            )
            return
        }

        pendingStartResult = result
        pendingStartArguments = arguments
        requestStreamPermissions()
    }

    private fun requestUsbAccessoryPermissionIfNeeded(
        arguments: Any?,
        result: MethodChannel.Result
    ): Boolean {
        if (!audioEngine.needsUsbAccessoryPermissionForStream()) {
            return false
        }

        val accessory = audioEngine.findAudioBridgeAccessory() ?: return false
        val usbManager = getSystemService(UsbManager::class.java)
        if (usbManager.hasPermission(accessory)) {
            return false
        }

        if (pendingStartResult != null) {
            result.error(
                "usb_permission_pending",
                "Native USB permission is already being requested.",
                null
            )
            return true
        }

        pendingStartResult = result
        pendingStartArguments = arguments
        registerUsbPermissionReceiver()

        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            }
        val permissionIntent = PendingIntent.getBroadcast(
            this,
            0,
            Intent(USB_PERMISSION_ACTION).setPackage(packageName),
            flags
        )
        usbManager.requestPermission(accessory, permissionIntent)
        return true
    }

    private fun registerUsbPermissionReceiver() {
        if (usbPermissionReceiverRegistered) {
            return
        }

        val filter = IntentFilter(USB_PERMISSION_ACTION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(usbPermissionReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(usbPermissionReceiver, filter)
        }
        usbPermissionReceiverRegistered = true
    }

    private fun startStream(arguments: Any?, result: MethodChannel.Result) {
        try {
            audioEngine.startStream(arguments)
            startAudioRelayService()
            result.success(null)
        } catch (error: IllegalStateException) {
            result.error("audio_engine", error.message, null)
        } catch (error: IllegalArgumentException) {
            result.error("audio_engine", error.message, null)
        }
    }

    private fun handleUsbAccessoryIntent(intent: Intent?) {
        if (intent?.action != UsbManager.ACTION_USB_ACCESSORY_ATTACHED) {
            return
        }

        Log.i("AudioBridgeUsb", "handling USB accessory intent")
        try {
            audioEngine.prepareUsbReceiver(null)
            startStreamWhenPermissionsAllowed(null, accessoryAutoStartResult())
        } catch (error: IllegalStateException) {
            showUsbAutoStartError(error.message)
        } catch (error: IllegalArgumentException) {
            showUsbAutoStartError(error.message)
        }
    }

    private fun accessoryAutoStartResult(): MethodChannel.Result {
        return object : MethodChannel.Result {
            override fun success(result: Any?) = Unit

            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                showUsbAutoStartError(errorMessage)
            }

            override fun notImplemented() = Unit
        }
    }

    private fun showUsbAutoStartError(message: String?) {
        Toast.makeText(
            this,
            message ?: "Unable to start native USB receiver.",
            Toast.LENGTH_LONG
        ).show()
    }

    private fun startAudioRelayService() {
        val intent = Intent(this, AudioRelayForegroundService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun stopAudioRelayService() {
        stopService(Intent(this, AudioRelayForegroundService::class.java))
    }

    private fun requestStreamPermissions() {
        val permissions = mutableListOf<String>()
        if (audioEngine.needsMicrophonePermissionForStream() && !microphoneAllowed()) {
            permissions.add(Manifest.permission.RECORD_AUDIO)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (!notificationsAllowed()) {
                permissions.add(Manifest.permission.POST_NOTIFICATIONS)
            }
        }

        if (permissions.isNotEmpty()) {
            requestPermissions(permissions.toTypedArray(), STREAM_PERMISSION_REQUEST_CODE)
        }
    }

    private fun streamPermissionsAllowed(): Boolean {
        return (!audioEngine.needsMicrophonePermissionForStream() || microphoneAllowed()) &&
            notificationsAllowed()
    }

    private fun microphoneAllowed(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun notificationsAllowed(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun networkInterfaces(): List<Map<String, Any>> {
        val interfaces = try {
            NetworkInterface.getNetworkInterfaces()
        } catch (_: Exception) {
            return emptyList()
        } ?: return emptyList()

        return Collections.list(interfaces).mapNotNull { item ->
            val usable = try {
                item.isUp && !item.isLoopback
            } catch (_: Exception) {
                false
            }
            if (!usable) {
                return@mapNotNull null
            }

            val addresses = try {
                Collections.list(item.inetAddresses)
                    .filterIsInstance<Inet4Address>()
                    .mapNotNull { it.hostAddress?.takeIf { address -> address.isNotBlank() } }
            } catch (_: Exception) {
                emptyList()
            }

            if (addresses.isEmpty()) {
                return@mapNotNull null
            }

            mapOf(
                "name" to item.name,
                "description" to item.displayName,
                "index" to item.index,
                "addresses" to addresses
            )
        }
    }

    companion object {
        private const val STREAM_PERMISSION_REQUEST_CODE = 47885
        private const val USB_PERMISSION_ACTION =
            "com.example.audiorelay_clone.USB_PERMISSION"
    }
}
