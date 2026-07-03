package com.audiobridge.app

import android.Manifest
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.usb.UsbManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import android.widget.Toast
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.Collections

class MainActivity : FlutterActivity() {
    private val audioEngine by lazy { AudioEngineHolder.receiverEngine(applicationContext) }
    private var pendingStartResult: MethodChannel.Result? = null
    private var pendingStartArguments: Any? = null
    private var pendingUpdateInstallFile: File? = null
    private var awaitingUpdateInstallPermission = false
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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val pendingInstallPath = savedInstanceState
            ?.getString(PENDING_UPDATE_INSTALL_PATH_KEY)
            ?.takeIf { it.isNotBlank() }
        if (pendingInstallPath != null) {
            pendingUpdateInstallFile = File(pendingInstallPath)
            awaitingUpdateInstallPermission = true
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

                    "playSoundEffect" -> {
                        result.error(
                            "sound_effects_unsupported",
                            "Soundboard injection is only available on Windows sender streams.",
                            null
                        )
                    }

                    "stopSoundEffects" -> {
                        result.success(null)
                    }

                    "disconnect" -> {
                        audioEngine.disconnect()
                        stopAudioRelayService()
                        result.success(null)
                    }

                    "openExternalUrl" -> {
                        openExternalUrl(call.arguments, result)
                    }

                    "installUpdatePackage" -> {
                        installUpdatePackage(call.arguments, result)
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

    override fun onResume() {
        super.onResume()
        resumePendingUpdateInstall()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        if (awaitingUpdateInstallPermission) {
            pendingUpdateInstallFile?.let { installFile ->
                outState.putString(PENDING_UPDATE_INSTALL_PATH_KEY, installFile.path)
            }
        }
        super.onSaveInstanceState(outState)
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

    private fun openExternalUrl(arguments: Any?, result: MethodChannel.Result) {
        val url = readStringArgument(arguments, "url")
        val uri = Uri.parse(url)
        if (uri.scheme != "https") {
            result.error("update_url", "The release link is not secure.", null)
            return
        }

        try {
            startActivity(Intent(Intent.ACTION_VIEW, uri))
            result.success(null)
        } catch (_: Exception) {
            result.error("update_url", "Unable to open release page.", null)
        }
    }

    private fun installUpdatePackage(arguments: Any?, result: MethodChannel.Result) {
        val path = readStringArgument(arguments, "path")
        val packageFile = File(path)
        if (!packageFile.exists() || packageFile.extension.lowercase() != "apk") {
            result.error("update_package", "The downloaded Android package is missing.", null)
            return
        }
        if (!isInAppStorage(packageFile)) {
            result.error("update_package", "The update package is outside app storage.", null)
            return
        }
        val installFile = prepareUpdatePackageForInstall(packageFile)
        if (installFile == null) {
            result.error("update_package", "Unable to prepare Android update package.", null)
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            pendingUpdateInstallFile = installFile
            awaitingUpdateInstallPermission = true
            val settingsIntent = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName")
            )
            try {
                startActivity(settingsIntent)
            } catch (_: Exception) {
                pendingUpdateInstallFile = null
                awaitingUpdateInstallPermission = false
                result.error(
                    "update_permission_screen",
                    "Unable to open the install permission screen.",
                    null
                )
                return
            }
            result.error(
                "update_install_permission",
                "Allow AudioBridge to install updates, then return to the app.",
                null
            )
            return
        }

        if (openUpdatePackageInstaller(installFile)) {
            result.success(null)
        } else {
            result.error("update_package", "Unable to open Android installer.", null)
        }
    }

    private fun resumePendingUpdateInstall() {
        if (!awaitingUpdateInstallPermission) {
            return
        }

        awaitingUpdateInstallPermission = false
        val installFile = pendingUpdateInstallFile
        pendingUpdateInstallFile = null

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            showUpdateInstallMessage(
                "Install permission was not granted. Tap Install to try again."
            )
            return
        }
        if (installFile == null || !installFile.exists() || !isInAppStorage(installFile)) {
            showUpdateInstallMessage("The downloaded Android package is missing.")
            return
        }
        if (!openUpdatePackageInstaller(installFile)) {
            showUpdateInstallMessage("Unable to open Android installer.")
        }
    }

    private fun openUpdatePackageInstaller(installFile: File): Boolean {
        return try {
            val packageUri = FileProvider.getUriForFile(
                this,
                "$packageName.update_file_provider",
                installFile
            )
            val installIntent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(packageUri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(installIntent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun showUpdateInstallMessage(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_LONG).show()
    }

    private fun isInAppStorage(file: File): Boolean {
        return try {
            val canonicalFile = file.canonicalFile
            val appDirectories = listOfNotNull(cacheDir, codeCacheDir, filesDir, noBackupFilesDir)
            appDirectories.any { directory ->
                val canonicalDirectory = directory.canonicalFile
                canonicalFile.path == canonicalDirectory.path ||
                    canonicalFile.path.startsWith(canonicalDirectory.path + File.separator)
            }
        } catch (_: Exception) {
            false
        }
    }

    private fun prepareUpdatePackageForInstall(packageFile: File): File? {
        return try {
            val installDirectory = File(cacheDir, "updates").apply { mkdirs() }
            val installFile = File(installDirectory, "AudioBridge-update.apk")
            val canonicalSource = packageFile.canonicalFile
            val canonicalInstallFile = installFile.canonicalFile
            if (canonicalSource.path != canonicalInstallFile.path) {
                canonicalSource.copyTo(canonicalInstallFile, overwrite = true)
            }
            canonicalInstallFile
        } catch (_: Exception) {
            null
        }
    }

    private fun readStringArgument(arguments: Any?, key: String): String {
        val payload = arguments as? Map<*, *> ?: return ""
        return payload[key]?.toString()?.trim() ?: ""
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
        val intent = Intent(this, AudioRelayForegroundService::class.java).apply {
            action = AudioRelayForegroundService.ACTION_START_STREAM
        }
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

            val addressMetadata = try {
                item.interfaceAddresses.mapNotNull { interfaceAddress ->
                    val address = interfaceAddress.address as? Inet4Address
                        ?: return@mapNotNull null
                    val hostAddress = address.hostAddress?.takeIf { it.isNotBlank() }
                        ?: return@mapNotNull null
                    buildMap<String, Any> {
                        put("address", hostAddress)
                        put(
                            "prefixLength",
                            interfaceAddress.networkPrefixLength.toInt().coerceIn(0, 32)
                        )
                        interfaceAddress.broadcast?.hostAddress
                            ?.takeIf { it.isNotBlank() }
                            ?.let { put("broadcastAddress", it) }
                    }
                }
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
                "addresses" to addresses,
                "addressMetadata" to addressMetadata
            )
        }
    }

    companion object {
        private const val PENDING_UPDATE_INSTALL_PATH_KEY =
            "audio_bridge_pending_update_install_path"
        private const val STREAM_PERMISSION_REQUEST_CODE = 47885
        private const val USB_PERMISSION_ACTION =
            "com.audiobridge.app.USB_PERMISSION"
    }
}
