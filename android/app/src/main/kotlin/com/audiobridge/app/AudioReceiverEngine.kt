package com.audiobridge.app

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.AudioTrack
import android.media.MediaRecorder
import android.net.wifi.WifiManager
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.Process
import android.os.SystemClock
import android.util.Log
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.SocketException
import java.net.SocketTimeoutException
import java.io.EOFException
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Collections
import java.util.Locale
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.min
import kotlin.math.max
import kotlin.math.roundToInt
import kotlin.math.roundToLong

private const val AUDIO_PORT = 47885
private const val MAX_PACKET_BYTES = 1200
private const val USB_FRAME_HEADER_BYTES = 4
private const val PACKET_HEADER_BYTES = 16
private const val PACKET_V2_HEADER_BYTES = 24
private const val PACKET_V3_HEADER_BYTES = 48
private const val PACKET_V4_HEADER_BYTES = 56
private const val PACKET_V5_HEADER_BYTES = 64
private const val PACKET_MAGIC = 0x31524241
private const val PACKET_V2_MAGIC = 0x32524241
private const val PACKET_V3_MAGIC = 0x33524241
private const val PACKET_V4_MAGIC = 0x34524241
private const val PACKET_V5_MAGIC = 0x35524241
private const val CODEC_PCM = 0
private const val CODEC_OPUS = 1
private const val CODEC_AAC = 2
private const val CODEC_G711_MU_LAW = 8
private const val CODEC_G711_A_LAW = 9
private const val CODEC_IMA_ADPCM = 10
private const val PACKET_KIND_AUDIO = 0
private const val PACKET_KIND_HEARTBEAT = 1
private const val PACKET_FLAG_MUTED = 1
private const val RECEIVER_OPTION_ADAPTIVE_BUFFER = 1
private const val RECEIVER_OPTION_MODE_SHIFT = 4
private const val RECEIVER_OPTION_MODE_MASK = 3 shl RECEIVER_OPTION_MODE_SHIFT
private const val RECEIVER_OPTION_CUSTOM_CAP_SHIFT = 8
private const val RECEIVER_OPTION_CUSTOM_CAP_MASK = 0x1FF shl RECEIVER_OPTION_CUSTOM_CAP_SHIFT
private const val RECEIVER_OPTION_BITRATE_SHIFT = 20
private const val RECEIVER_OPTION_BITRATE_MASK = 0xFFF
private const val AAC_SAMPLES_PER_FRAME = 1024
private const val AAC_CODEC_TIMEOUT_US = 5000L
private const val SUBSCRIBE_MESSAGE = "ABR_SUBSCRIBE v1"
private const val MIN_LATENCY_MS = 5
private const val USB_MIN_LATENCY_MS = 5
private const val MAX_LATENCY_MS = 500
private const val LOW_LATENCY_PERFORMANCE_MAX_MS = 80
private const val LOW_DELAY_TRAFFIC_CLASS = 0xB8
private const val UDP_BUFFER_BYTES = 256 * 1024
private const val SUBSCRIBE_INTERVAL_MS = 300L
private const val SUBSCRIBE_MAX_BYTES = 2048
private const val SOURCE_IDLE_TIMEOUT_MS = 1200L
private const val PEER_HEARTBEAT_TIMEOUT_MS = 3000L
private const val HEARTBEAT_INTERVAL_MS = 800L
private const val START_BUFFER_PACKETS = 4
private const val START_BUFFER_EXTRA_MS = 2
private const val ADAPTIVE_BUFFER_COOLDOWN_MS = 1500L
private const val ADAPTIVE_BUFFER_RELAX_MS = 6000L
private const val ADAPTIVE_BUFFER_FAST_RELAX_MS = 2500L
private const val ADAPTIVE_GAMING_BUFFER_RELAX_MS = 1200L
private const val ADAPTIVE_GAMING_BUFFER_FAST_RELAX_MS = 700L
private const val ADAPTIVE_PLAYBACK_START_GRACE_MS = 1000L
private const val ADAPTIVE_UNDERRUN_SLOW_WINDOW_MS = 15000L
private const val ADAPTIVE_ACCEPTABLE_UNDERRUNS_PER_SLOW_WINDOW = 6
private const val ADAPTIVE_UNDERRUN_BURST_WINDOW_MS = 2000L
private const val ADAPTIVE_ACCEPTABLE_UNDERRUNS_PER_BURST = 4
private const val ADAPTIVE_LOW_QUEUE_DIVISOR = 4L
private const val ADAPTIVE_LOW_QUEUE_GROWTH_SAMPLES = 3
private const val ADAPTIVE_LOW_LATENCY_STEP_MS = 4
private const val ADAPTIVE_GAMING_RELAX_STEP_MS = 1
private const val ADAPTIVE_BALANCED_STEP_MS = 8
private const val ADAPTIVE_STABLE_STEP_MS = 20
private const val ADAPTIVE_GAMING_CAP_MS = 120
private const val ADAPTIVE_BALANCED_CAP_MS = 240
private const val ADAPTIVE_DELAY_SAMPLE_INTERVAL_MS = 500L
private const val ADAPTIVE_DELAY_HISTORY_SAMPLES = 32
private const val ADAPTIVE_DELAY_MIN_HISTORY_SAMPLES = 4
private const val ADAPTIVE_DELAY_QUANTILE = 0.75
private const val ADAPTIVE_DELAY_HEADROOM_NUMERATOR = 3
private const val ADAPTIVE_DELAY_HEADROOM_DENOMINATOR = 5
private const val ADAPTIVE_DELAY_MAX_MS = 2000.0
private const val ADAPTIVE_SEQUENCE_RESET_GAP = 50L
private const val ADAPTIVE_NETWORK_TARGET_HYSTERESIS_MS = 5
private const val ADAPTIVE_FAST_RELAX_MARGIN_MS = 8
private const val ADAPTIVE_AUDIBLE_SIGNAL_FLOOR = 0.001
private const val ADAPTIVE_LINK_MEMORY_PREFS = "audio_bridge_adaptive_link_memory"
private const val ADAPTIVE_LINK_MEMORY_VERSION = 1
private const val ADAPTIVE_LINK_MEMORY_MAX_AGE_MS = 14L * 24L * 60L * 60L * 1000L
private const val ADAPTIVE_LINK_MEMORY_WRITE_COOLDOWN_MS = 1500L
private const val SEQUENCE_MODULUS = 0x1_0000_0000L
private const val AAC_MIME_TYPE = "audio/mp4a-latm"
private const val OPUS_SAMPLE_RATE = 48000
private const val OPUS_LOW_FRAME_SAMPLES = OPUS_SAMPLE_RATE * 25 / 10000
private const val OPUS_SHORT_FRAME_MS = 5
private const val OPUS_LONG_FRAME_MS = 10
private const val OPUS_SHORT_FRAME_SAMPLES = OPUS_SAMPLE_RATE * OPUS_SHORT_FRAME_MS / 1000
private const val OPUS_LONG_FRAME_SAMPLES = OPUS_SAMPLE_RATE * OPUS_LONG_FRAME_MS / 1000
private const val CD_SAMPLE_RATE = 44100
private const val MAX_OUTPUT_SAMPLE_RATE = 192000
private const val ACCESSORY_MANUFACTURER = "AudioBridge"
private const val ACCESSORY_MODEL = "AudioBridge Native USB"
private const val LOG_TAG = "AudioBridgeUsb"
private const val RECEIVER_SUPPORTED_CODECS =
    "pcm,opus,aac,g711MuLaw,g711ALaw,imaAdpcm"

internal enum class LatencyRecoveryDecision {
    ACCEPT,
    DROP,
    TRIM_AND_ACCEPT,
    TRIM_AND_DROP
}

internal fun latencyRecoveryDecision(
    queuedFrames: Long,
    targetFrames: Long,
    packetFrames: Long,
    hardLimitFrames: Long,
    sampleRate: Int,
    networkSampleMs: Double?
): LatencyRecoveryDecision {
    if (sampleRate <= 0) {
        return LatencyRecoveryDecision.DROP
    }

    val boundedPacketFrames = max(1L, packetFrames)
    if (networkSampleMs != null) {
        val queuedMs = queuedFrames * 1000.0 / sampleRate
        val hardLimitMs = hardLimitFrames * 1000.0 / sampleRate
        if (networkSampleMs + queuedMs > hardLimitMs) {
            val queueCanRecover = queuedFrames > targetFrames + boundedPacketFrames
            if (queueCanRecover) {
                return if (networkSampleMs <= hardLimitMs) {
                    LatencyRecoveryDecision.TRIM_AND_ACCEPT
                } else {
                    LatencyRecoveryDecision.TRIM_AND_DROP
                }
            }
            if (queuedFrames <= targetFrames) {
                return LatencyRecoveryDecision.ACCEPT
            }
            return LatencyRecoveryDecision.DROP
        }
    }

    if (queuedFrames > hardLimitFrames) {
        return LatencyRecoveryDecision.TRIM_AND_ACCEPT
    }

    return LatencyRecoveryDecision.ACCEPT
}

internal fun shouldGrowAdaptiveBufferForLowQueue(lowQueueSamples: Int): Boolean {
    return lowQueueSamples >= ADAPTIVE_LOW_QUEUE_GROWTH_SAMPLES
}

internal fun adaptiveBufferIncreaseTargetMs(
    currentBufferMs: Int,
    stepMs: Int,
    networkFloorMs: Int,
    pressureIncrease: Boolean,
    networkFloorIncrease: Boolean
): Int {
    val stepTargetMs = currentBufferMs + stepMs
    return if (pressureIncrease || networkFloorIncrease) {
        max(stepTargetMs, networkFloorMs)
    } else {
        stepTargetMs
    }
}

internal fun acceptsSessionPacket(expectedSessionId: Long, packetSessionId: Long): Boolean {
    return expectedSessionId > 0L && packetSessionId == expectedSessionId
}

internal fun acceptsLegacyPacket(sessionProtocolActive: Boolean): Boolean {
    return !sessionProtocolActive
}

internal enum class TransportMode {
    WIFI,
    USB_TETHERING,
    USB
}

internal fun transportModeFromName(value: String?): TransportMode {
    val normalized = value
        ?.lowercase(Locale.US)
        ?.replace(Regex("[-_\\s]"), "")
    return when (normalized) {
        "usb" -> TransportMode.USB
        "usbtethering", "tethering" -> TransportMode.USB_TETHERING
        else -> TransportMode.WIFI
    }
}

internal fun requiresWifiLock(transportMode: TransportMode): Boolean {
    return transportMode == TransportMode.WIFI
}

internal fun shouldParkIdlePlayback(sourceIdle: Boolean, peerConnected: Boolean): Boolean {
    return sourceIdle && !peerConnected
}

private enum class OutputAudioBackend {
    AUTO,
    AUDIO_TRACK,
    OBOE;

    companion object {
        fun fromName(value: String?): OutputAudioBackend {
            return when (value?.lowercase(Locale.US)) {
                "audiotrack" -> AUDIO_TRACK
                "oboe" -> OBOE
                else -> AUTO
            }
        }
    }
}

private enum class AudioMode(val packetId: Int) {
    BALANCED(0),
    GAMING(1),
    MUSIC(2),
    CUSTOM(3);

    companion object {
        fun fromName(value: String?): AudioMode {
            return when (value?.lowercase(Locale.US)?.replace(Regex("[-_\\s]"), "")) {
                "gaming", "game", "lowlatency" -> GAMING
                "balanced", "balance" -> BALANCED
                "music", "stable", "stability" -> MUSIC
                "custom", "user", "manual" -> CUSTOM
                else -> BALANCED
            }
        }

        fun fromPacketId(value: Int): AudioMode {
            return when (value) {
                GAMING.packetId -> GAMING
                MUSIC.packetId -> MUSIC
                CUSTOM.packetId -> CUSTOM
                else -> BALANCED
            }
        }
    }
}

private enum class EngineRole {
    RECEIVER,
    SENDER
}

private data class SenderAudioCapture(
    val record: AudioRecord,
    val sampleRate: Int,
    val channels: Int,
    val bufferSizeBytes: Int
)

private data class EncodedAudioPacket(
    val codecId: Int,
    val payload: ByteArray,
    val decodedFrameCount: Int,
    val flags: Int
)

private data class AdaptiveNetworkIdentity(
    val interfaceName: String,
    val interfaceDescription: String,
    val prefixLength: Int,
    val localSubnet: String,
    val peerSubnet: String
)

private data class RemoteReceiverClockEcho(
    val receiverTimeMs: Long = 0L,
    val receivedAtSenderTimeMs: Long = 0L
)

private data class SenderPeer(
    val endpoint: InetSocketAddress?,
    val sessionId: Long?
)

class AudioReceiverEngine(private val context: Context) {
    private var profile = AudioProfile()
    private var engineRole = EngineRole.RECEIVER
    private var source: InetSocketAddress? = null
    @Volatile
    private var senderPeer: SenderPeer? = null
    private var transportMode = TransportMode.WIFI
    private var networkBindAddress: InetAddress? = null
    private var socket: DatagramSocket? = null
    private var usbConnection: ParcelFileDescriptor? = null
    private var usbInput: FileInputStream? = null
    private var usbOutput: FileOutputStream? = null
    private val usbIoLock = Any()
    private val usbWriteLock = Any()
    private var receiveThread: Thread? = null
    private var senderControlThread: Thread? = null
    private var captureThread: Thread? = null
    private var audioRecord: AudioRecord? = null
    private var senderSequence = 0
    private var packetizerPendingPcm = ShortArray(0)
    private var packetizerPendingSamples = 0
    private var packetizerSentFrames = 0L
    private var packetizerPacketCount = 0L
    private var packetizerSampleRate = 0
    private var packetizerChannels = 0
    private var packetizerPacketTimeMs = 0
    private var packetizerCodecId = CODEC_PCM
    private var aacEncoder: MediaCodec? = null
    private var aacEncoderSampleRate = 0
    private var aacEncoderChannels = 0
    private var aacEncoderBitrateBps = 0
    private var aacEncoderSubmittedFrames = 0L

    @Volatile
    private var audioTrack: AudioTrack? = null
    private var currentInputSampleRate = 0
    private var currentSampleRate = 0
    private var currentChannels = 0
    private var currentBufferSizeFrames = 0
    private var currentTargetBufferFrames = 0
    private var currentUseBlockingWrites = false
    private var adaptivePlaybackBufferMs = 35
    private var lastAdaptiveBufferIncreaseAtMs = 0L
    private var lastAdaptiveBufferRelaxAtMs = 0L
    private var lastPlaybackPressureAtMs = 0L
    private var playbackStartedAtMs = 0L
    private var lastKnownUnderrunCount = 0
    private var adaptiveUnderrunWindowStartAtMs = 0L
    private var adaptiveUnderrunsInWindow = 0
    private var adaptiveUnderrunBurstStartAtMs = 0L
    private var adaptiveUnderrunsInBurst = 0
    private var adaptiveLowQueueSamples = 0
    private var adaptiveLastArrivalSequence = -1L
    private var adaptiveLastArrivalAtMs = 0L
    private var adaptiveLastPacketDurationMs = 0.0
    private var adaptiveRelativeDelayMs = 0.0
    private var adaptiveDelayWindowStartAtMs = 0L
    private var adaptiveDelayWindowPeakMs = 0.0
    private val adaptiveDelayHistoryMs = IntArray(ADAPTIVE_DELAY_HISTORY_SAMPLES)
    private var adaptiveDelayHistoryIndex = 0
    private var adaptiveDelayHistoryCount = 0
    private var adaptiveNetworkTargetBufferMs = 0
    private val adaptiveLinkPreferences by lazy {
        context.getSharedPreferences(ADAPTIVE_LINK_MEMORY_PREFS, Context.MODE_PRIVATE)
    }
    private var adaptiveLinkMemoryKey: String? = null
    private var lastAdaptiveLinkMemoryWriteAtMs = 0L
    private var lastPlaybackHead = 0
    private var playbackHeadWraps = 0L
    private var lastSequence = -1L
    private var lastAudioPacketReceivedAtMs = 0L
    private var lastPeerPacketReceivedAtMs = 0L
    private var receiverSessionId = 0L
    private var sessionProtocolActive = false
    private var lastHeartbeatSentAtMs = 0L
    private val sessionRandom = SecureRandom()
    private var lastCodecId = CODEC_PCM
    private val nativeOutputSampleRate = readNativeOutputSampleRate()
    private val opusNative = OpusNative()
    private var opusDecoderHandle = 0L
    private var opusChannels = 0
    private var opusEncoderHandle = 0L
    private var opusEncoderChannels = 0
    private var opusEncoderBitrateBps = 0
    private var opusEncoderLowDelay = false
    private var aacDecoder: MediaCodec? = null
    private var aacSampleRate = 0
    private var aacChannels = 0
    private var pcmReformatterInitialized = false
    private var pcmReformatterSourceCursor = 0.0
    private var pcmReformatterInputFramesConsumed = 0L
    private var pcmReformatterInputSampleRate = 0
    private var pcmReformatterChannels = 0
    private var pcmReformatterOutputSampleRate = 0
    private val writtenFrames = AtomicLong(0)
    private val droppedPackets = AtomicLong(0)
    private val lostPackets = AtomicLong(0)
    private val trimCount = AtomicLong(0)

    @Volatile
    private var audioLatencyMs = Double.NaN

    @Volatile
    private var networkLatencyMs = Double.NaN

    @Volatile
    private var signalLevel = 0.0

    @Volatile
    private var running = false

    @Volatile
    private var senderControlRunning = false

    @Volatile
    private var volume = 0.86f

    @Volatile
    private var muted = false

    @Volatile
    private var remoteOutputLatencyMs = Double.NaN

    @Volatile
    private var remoteAudioLatencyMs = Double.NaN

    @Volatile
    private var remoteNetworkLatencyMs = Double.NaN

    @Volatile
    private var remoteSignalLevel = 0.0

    @Volatile
    private var remotePlatform: String? = null

    @Volatile
    private var remoteSupportedCodecs: List<String> = emptyList()

    private val remoteQueuedFrames = AtomicLong(0)
    private val remoteBufferSizeFrames = AtomicLong(0)
    private val remoteTargetBufferFrames = AtomicLong(0)
    private val remoteAdaptivePlaybackBufferMs = AtomicLong(0)
    private val remoteAdaptiveMaxPlaybackBufferMs = AtomicLong(0)
    private val remoteAdaptiveLimitReached = AtomicLong(0)
    private val remoteAdaptiveUnderrunsInWindow = AtomicLong(0)
    private val remoteAdaptiveUnderrunsInBurst = AtomicLong(0)
    private val remoteAdaptiveLowQueueSamples = AtomicLong(0)
    private val remotePlaybackQueueFillPercent = AtomicLong(0)
    private val remoteUnderrunCount = AtomicLong(0)
    private val remoteDroppedPacketCount = AtomicLong(0)
    private val remoteLostPacketCount = AtomicLong(0)
    private val remoteTrimCount = AtomicLong(0)
    private val remoteMetricsReceivedAtMs = AtomicLong(0)

    @Volatile
    private var remoteReceiverClockEcho = RemoteReceiverClockEcho()

    private var usbFramesReceived = 0L
    private var usbSubscribeFramesSent = 0L
    private var usbAudioPacketsHandled = 0L
    private var audioTrackCreateCount = 0L
    private var audioTrackWriteCount = 0L
    private var unknownUsbPacketCount = 0L

    fun getCapabilities(): Map<String, Any> = mapOf(
        "platform" to "android",
        "canSend" to true,
        "canReceive" to true,
        "canPlaySoundEffects" to false,
        "backend" to "android-audiorecord-audiotrack-codecs-udp-native-usb",
        "detail" to "Low-latency UDP microphone capture plus UDP, USB tethering, and Android Open Accessory USB playback",
        "supportedCodecs" to listOf("pcm", "opus", "aac", "g711MuLaw", "g711ALaw", "imaAdpcm"),
        "supportedOutputBackends" to listOf("auto", "audioTrack"),
        "codecBitrateRanges" to mapOf(
            "pcm" to mapOf("minKbps" to 0, "maxKbps" to 0),
            "opus" to mapOf("minKbps" to 64, "maxKbps" to 256),
            "aac" to mapOf("minKbps" to 96, "maxKbps" to 192),
            "g711MuLaw" to mapOf("minKbps" to 64, "maxKbps" to 1536),
            "g711ALaw" to mapOf("minKbps" to 64, "maxKbps" to 1536),
            "imaAdpcm" to mapOf("minKbps" to 32, "maxKbps" to 768)
        )
    )

    fun getMetrics(): Map<String, Any> {
        val now = SystemClock.elapsedRealtime()
        if (engineRole == EngineRole.SENDER) {
            val metrics = mutableMapOf<String, Any>()
            if (running) {
                metrics["signalLevel"] = signalLevel
            }

            val receivedAt = remoteMetricsReceivedAtMs.get()
            val peerConnected = receivedAt > 0 && now - receivedAt <= 3000L
            metrics["peerConnected"] = peerConnected
            if (!peerConnected) {
                return metrics
            }

            metrics.putAll(mapOf(
                "queuedFrames" to remoteQueuedFrames.get(),
                "bufferSizeFrames" to remoteBufferSizeFrames.get(),
                "targetBufferFrames" to remoteTargetBufferFrames.get(),
                "adaptivePlaybackBufferMs" to remoteAdaptivePlaybackBufferMs.get(),
                "adaptiveMaxPlaybackBufferMs" to remoteAdaptiveMaxPlaybackBufferMs.get(),
                "adaptiveLimitReached" to (remoteAdaptiveLimitReached.get() > 0L),
                "adaptiveUnderrunsInWindow" to remoteAdaptiveUnderrunsInWindow.get(),
                "adaptiveUnderrunsInBurst" to remoteAdaptiveUnderrunsInBurst.get(),
                "adaptiveLowQueueSamples" to remoteAdaptiveLowQueueSamples.get(),
                "playbackQueueFillPercent" to remotePlaybackQueueFillPercent.get(),
                "underrunCount" to remoteUnderrunCount.get(),
                "droppedPacketCount" to remoteDroppedPacketCount.get(),
                "lostPacketCount" to remoteLostPacketCount.get(),
                "trimCount" to remoteTrimCount.get()
            ))
            if (!running) {
                metrics["signalLevel"] = remoteSignalLevel
            }
            if (!remoteAudioLatencyMs.isNaN()) {
                metrics["audioLatencyMs"] = remoteAudioLatencyMs
            }
            if (!remoteOutputLatencyMs.isNaN()) {
                metrics["outputLatencyMs"] = remoteOutputLatencyMs
            }
            if (!remoteNetworkLatencyMs.isNaN()) {
                metrics["networkLatencyMs"] = remoteNetworkLatencyMs
            }
            remotePlatform?.let { metrics["remotePlatform"] = it }
            if (remoteSupportedCodecs.isNotEmpty()) {
                metrics["remoteSupportedCodecs"] = remoteSupportedCodecs
            }
            return metrics
        }

        val sampleRate = currentSampleRate.takeIf { it > 0 } ?: profile.sampleRate
        val peerConnected = isPeerConnected(now)
        val track = audioTrack
        if (track == null) {
            return idleReceiverMetrics(sampleRate, peerConnected)
        }
        val playedFrames = playbackFrames(track)
        val queuedFrames = max(0L, writtenFrames.get() - playedFrames)
        val underruns = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            track.underrunCount
        } else {
            0
        }
        val sourceIdle = isSourceIdle(now)
        if (sourceIdle) {
            if (shouldParkIdlePlayback(sourceIdle, peerConnected)) {
                parkIdlePlayback(track, underruns)
            }
            return idleReceiverMetrics(sampleRate, peerConnected)
        }

        val outputLatencyMs = queuedFrames * 1000.0 / sampleRate
        adaptPlaybackBuffer(track, sampleRate, queuedFrames, underruns)
        val adaptiveMaxBufferMs = adaptiveMaxPlaybackBufferMs()

        val metrics = mutableMapOf<String, Any>(
            "outputLatencyMs" to outputLatencyMs,
            "queuedFrames" to queuedFrames,
            "bufferSizeFrames" to currentBufferSizeFrames,
            "targetBufferFrames" to currentTargetBufferFrames,
            "adaptivePlaybackBufferMs" to adaptivePlaybackBufferMs,
            "adaptiveMaxPlaybackBufferMs" to adaptiveMaxBufferMs,
            "adaptiveLimitReached" to (
                profile.receiverAdaptiveBuffer &&
                    adaptivePlaybackBufferMs >= adaptiveMaxBufferMs
                ),
            "adaptiveUnderrunsInWindow" to adaptiveUnderrunsInWindow,
            "adaptiveUnderrunsInBurst" to adaptiveUnderrunsInBurst,
            "adaptiveLowQueueSamples" to adaptiveLowQueueSamples,
            "playbackQueueFillPercent" to playbackQueueFillPercent(
                queuedFrames,
                currentTargetBufferFrames
            ),
            "underrunCount" to underruns,
            "droppedPacketCount" to droppedPackets.get(),
            "lostPacketCount" to lostPackets.get(),
            "trimCount" to trimCount.get(),
            "signalLevel" to signalLevel,
            "peerConnected" to peerConnected,
            "sourceAudioActive" to true,
            "activeProfile" to activeProfileForMetrics()
        )
        if (!audioLatencyMs.isNaN()) {
            metrics["audioLatencyMs"] = audioLatencyMs
        }
        if (!networkLatencyMs.isNaN()) {
            metrics["networkLatencyMs"] = networkLatencyMs
        }
        return metrics
    }

    private fun isSourceIdle(now: Long): Boolean {
        val lastPacketAt = lastAudioPacketReceivedAtMs
        return lastPacketAt <= 0L || now - lastPacketAt > SOURCE_IDLE_TIMEOUT_MS
    }

    private fun isPeerConnected(now: Long): Boolean {
        val lastPacketAt = lastPeerPacketReceivedAtMs
        return lastPacketAt > 0L && now - lastPacketAt <= PEER_HEARTBEAT_TIMEOUT_MS
    }

    private fun idleReceiverMetrics(
        sampleRate: Int,
        peerConnected: Boolean = false
    ): Map<String, Any> {
        val activeSampleRate = sampleRate.takeIf { it > 0 } ?: profile.sampleRate
        val requestedLatencyMs = profile.playbackBufferMs.coerceIn(
            minLatencyMs(),
            MAX_LATENCY_MS
        )
        val activeLatencyMs = adaptivePlaybackBufferMs.coerceIn(
            requestedLatencyMs,
            adaptiveMaxPlaybackBufferMs(requestedLatencyMs)
        )
        val targetFrames = latencyFrames(activeSampleRate, activeLatencyMs)
        val adaptiveMaxBufferMs = adaptiveMaxPlaybackBufferMs(requestedLatencyMs)
        adaptivePlaybackBufferMs = activeLatencyMs
        resetAdaptiveDelayTracker()
        signalLevel = 0.0

        return mapOf(
            "outputLatencyMs" to 0.0,
            "queuedFrames" to 0L,
            "bufferSizeFrames" to currentBufferSizeFrames,
            "targetBufferFrames" to if (currentBufferSizeFrames > 0) {
                min(currentBufferSizeFrames, targetFrames)
            } else {
                targetFrames
            },
            "adaptivePlaybackBufferMs" to activeLatencyMs,
            "adaptiveMaxPlaybackBufferMs" to adaptiveMaxBufferMs,
            "adaptiveLimitReached" to false,
            "adaptiveUnderrunsInWindow" to 0,
            "adaptiveUnderrunsInBurst" to 0,
            "adaptiveLowQueueSamples" to 0,
            "playbackQueueFillPercent" to 0,
            "underrunCount" to 0,
            "droppedPacketCount" to droppedPackets.get(),
            "lostPacketCount" to lostPackets.get(),
            "trimCount" to trimCount.get(),
            "signalLevel" to 0.0,
            "peerConnected" to peerConnected,
            "sourceAudioActive" to false,
            "activeProfile" to activeProfileForMetrics()
        )
    }

    private fun parkIdlePlayback(track: AudioTrack, underruns: Int) {
        try {
            if (track.playState == AudioTrack.PLAYSTATE_PLAYING) {
                track.pause()
            }
            track.flush()
        } catch (_: IllegalStateException) {
        }
        writtenFrames.set(playbackFrames(track))
        lastKnownUnderrunCount = underruns
        adaptiveUnderrunWindowStartAtMs = 0L
        adaptiveUnderrunsInWindow = 0
        adaptiveUnderrunBurstStartAtMs = 0L
        adaptiveUnderrunsInBurst = 0
        adaptiveLowQueueSamples = 0
        resetAdaptiveDelayTracker()
        lastAdaptiveBufferRelaxAtMs = SystemClock.elapsedRealtime()
        signalLevel = 0.0
    }

    private fun activeProfileForMetrics(): Map<String, Any> {
        val activeSampleRate = currentInputSampleRate.takeIf { it > 0 } ?: profile.sampleRate
        val activeChannels = currentChannels.takeIf { it > 0 } ?: profile.channels
        return profile.copy(
            codec = lastCodecId,
            sampleRate = activeSampleRate,
            channels = activeChannels
        ).toMap()
    }

    fun needsMicrophonePermissionForStream(): Boolean {
        return engineRole == EngineRole.SENDER
    }

    fun needsUsbAccessoryPermissionForStream(): Boolean {
        return transportMode == TransportMode.USB
    }

    fun needsWifiLockForStream(): Boolean {
        return requiresWifiLock(transportMode)
    }

    fun isStreamActive(): Boolean {
        return running
    }

    fun prepareReceiver(arguments: Any?) {
        if (engineRole == EngineRole.SENDER) {
            stopSenderCapture()
            stopSenderControl()
        } else {
            stopStream()
        }
        engineRole = EngineRole.RECEIVER
        profile = AudioProfile.from(arguments)
        transportMode = TransportMode.WIFI
        networkBindAddress = null
        adaptiveLinkMemoryKey = null
        validateOutputBackend()
        closeUsbConnection()
    }

    fun prepareUsbReceiver(arguments: Any?) {
        Log.i(LOG_TAG, "prepareUsbReceiver")
        prepareReceiver(arguments)
        transportMode = TransportMode.USB
        networkBindAddress = null
        source = null
        socket?.close()
        socket = null
    }

    fun prepareSender(arguments: Any?) {
        if (engineRole == EngineRole.RECEIVER) {
            stopStream()
        }
        engineRole = EngineRole.SENDER
        profile = AudioProfile.from(arguments)
        transportMode = transportModeFromName(
            (arguments as? Map<*, *>)?.get("transport")?.toString()
        )
        networkBindAddress = null
        source = null
        adaptiveLinkMemoryKey = null
        closeUsbConnection()
        releaseAudioTrack()
        if (socket == null || socket?.isClosed == true) {
            socket = openSenderSocket()
        }
        startSenderControl()
    }

    fun prepareUsbSender(arguments: Any?) {
        if (engineRole == EngineRole.RECEIVER) {
            stopStream()
        } else {
            stopSenderControl()
        }
        engineRole = EngineRole.SENDER
        profile = AudioProfile.from(arguments)
        transportMode = TransportMode.USB
        networkBindAddress = null
        source = null
        senderPeer = null
        adaptiveLinkMemoryKey = null
        socket?.close()
        socket = null
        releaseAudioTrack()
        resetRemoteMetrics()
    }

    fun connectToSender(arguments: Any?) {
        if (engineRole == EngineRole.SENDER) {
            stopSenderCapture()
            stopSenderControl()
        }
        engineRole = EngineRole.RECEIVER
        val payload = arguments as? Map<*, *> ?: error("Missing connection payload.")
        val device = payload["device"] as? Map<*, *> ?: error("Missing sender device.")
        profile = AudioProfile.from(payload["profile"])
        validateOutputBackend()

        val host = device["host"]?.toString()?.takeIf { it.isNotBlank() }
            ?: error("Missing sender host.")
        val port = (device["port"] as? Number)?.toInt() ?: AUDIO_PORT
        transportMode = transportModeFromName(device["transport"]?.toString())

        val hostAddress = InetAddress.getByName(host)
        source = InetSocketAddress(hostAddress, port)
        networkBindAddress = receiverBindAddressForPeer(hostAddress, host)
        refreshAdaptiveLinkMemoryKey()

        if (transportMode == TransportMode.USB) {
            socket?.close()
            socket = null
            return
        }

        if (socket == null || socket?.isClosed == true) {
            socket = openAudioSocket(networkBindAddress)
        }

        // The subscribe packet is sent from the receive thread. Android's
        // method channel handler runs on the main thread, where UDP send is
        // blocked by StrictMode.
    }

    fun startStream(arguments: Any?) {
        profile = AudioProfile.from(arguments)
        Log.i(
            LOG_TAG,
            "startStream role=$engineRole transport=$transportMode sampleRate=${profile.sampleRate} channels=${profile.channels} codec=${profile.codec}"
        )
        if (engineRole == EngineRole.SENDER) {
            startSenderStream()
            return
        }

        validateOutputBackend()

        if (running) {
            return
        }
        if (source == null && transportMode != TransportMode.USB) {
            error("No sender selected.")
        }
        if (transportMode != TransportMode.USB && (socket == null || socket?.isClosed == true)) {
            socket = openAudioSocket(networkBindAddress)
        }

        running = true
        droppedPackets.set(0)
        lostPackets.set(0)
        trimCount.set(0)
        releaseOpusDecoder()
        releaseAacDecoder()
        val now = SystemClock.elapsedRealtime()
        refreshAdaptiveLinkMemoryKey()
        adaptivePlaybackBufferMs = initialAdaptivePlaybackBufferMs()
        lastAdaptiveBufferIncreaseAtMs = 0L
        lastAdaptiveBufferRelaxAtMs = now
        lastPlaybackPressureAtMs = now
        playbackStartedAtMs = 0L
        lastKnownUnderrunCount = 0
        adaptiveUnderrunWindowStartAtMs = 0L
        adaptiveUnderrunsInWindow = 0
        adaptiveUnderrunBurstStartAtMs = 0L
        adaptiveUnderrunsInBurst = 0
        adaptiveLowQueueSamples = 0
        resetAdaptiveDelayTracker()
        audioLatencyMs = Double.NaN
        networkLatencyMs = Double.NaN
        signalLevel = 0.0
        lastAudioPacketReceivedAtMs = 0L
        lastPeerPacketReceivedAtMs = 0L
        receiverSessionId = nextSessionId()
        sessionProtocolActive = false
        lastSequence = -1L
        lastCodecId = CODEC_PCM
        receiveThread = Thread({
            if (transportMode == TransportMode.USB) {
                usbReceiveLoop()
            } else {
                receiveLoop()
            }
        }, "AudioBridgeReceiver").apply {
            isDaemon = true
            start()
        }
    }

    fun stopStream() {
        if (engineRole == EngineRole.SENDER) {
            stopSenderCapture()
            return
        }

        running = false
        socket?.close()
        closeUsbConnection()
        receiveThread?.join(800)
        receiveThread = null
        socket = null
        releaseOpusDecoder()
        releaseAacDecoder()
        releaseAudioTrack()
        lastPeerPacketReceivedAtMs = 0L
        receiverSessionId = 0L
        sessionProtocolActive = false
    }

    fun setVolume(arguments: Any?) {
        val value = (arguments as? Map<*, *>)?.get("value") as? Number ?: return
        volume = value.toFloat().coerceIn(0f, 1f)
        audioTrack?.setVolume(if (muted) 0f else volume)
    }

    fun setMuted(arguments: Any?) {
        muted = (arguments as? Map<*, *>)?.get("value") as? Boolean ?: return
        audioTrack?.setVolume(if (muted) 0f else volume)
    }

    fun disconnect() {
        if (engineRole == EngineRole.SENDER) {
            stopSenderCapture()
            stopSenderControl()
        } else {
            stopStream()
        }
        source = null
        transportMode = TransportMode.WIFI
        networkBindAddress = null
        adaptiveLinkMemoryKey = null
        engineRole = EngineRole.RECEIVER
        closeUsbConnection()
        releaseOpusDecoder()
        releaseAacDecoder()
    }

    private fun validateOutputBackend() {
        if (profile.outputBackend == OutputAudioBackend.OBOE) {
            error("Oboe/AAudio output is not implemented yet. Use Auto or AudioTrack.")
        }
    }

    private fun openAudioSocket(bindAddress: InetAddress? = null): DatagramSocket {
        return DatagramSocket(null).apply {
            reuseAddress = true
            soTimeout = 60
            applyLowDelaySocketOptions()
            bind(InetSocketAddress(bindAddress, 0))
        }
    }

    private fun reopenReceiverSocket(failedSocket: DatagramSocket?) {
        if (!running || engineRole != EngineRole.RECEIVER || transportMode == TransportMode.USB) {
            return
        }

        val currentSocket = socket
        if (failedSocket != null && currentSocket != null && currentSocket !== failedSocket) {
            return
        }

        currentSocket?.close()
        if (socket === currentSocket) {
            socket = null
        }

        socket = try {
            openAudioSocket(networkBindAddress)
        } catch (error: SocketException) {
            droppedPackets.incrementAndGet()
            Log.w(LOG_TAG, "unable to reopen receiver audio socket", error)
            sleepSocketRetry()
            null
        } catch (error: RuntimeException) {
            droppedPackets.incrementAndGet()
            Log.w(LOG_TAG, "receiver audio socket reopen failed", error)
            sleepSocketRetry()
            null
        }
    }

    private fun sleepSocketRetry() {
        try {
            Thread.sleep(80)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    private fun openSenderSocket(): DatagramSocket {
        return DatagramSocket(null).apply {
            reuseAddress = true
            soTimeout = 60
            applyLowDelaySocketOptions()
            bind(InetSocketAddress(AUDIO_PORT))
        }
    }

    private fun receiverBindAddressForPeer(peer: InetAddress, hostLabel: String): InetAddress? {
        val localAddress = localAddressForPeer(peer)
        return when (transportMode) {
            TransportMode.USB_TETHERING -> localAddress
                ?: error("No USB tethering audio interface was found for $hostLabel.")
            TransportMode.WIFI -> localAddress
            TransportMode.USB -> null
        }
    }

    private fun localAddressForPeer(peer: InetAddress): InetAddress? {
        if (peer !is Inet4Address) {
            return null
        }

        val interfaces = try {
            NetworkInterface.getNetworkInterfaces()
        } catch (_: SocketException) {
            null
        } ?: return null

        for (networkInterface in Collections.list(interfaces)) {
            val usable = try {
                networkInterface.isUp && !networkInterface.isLoopback
            } catch (_: SocketException) {
                false
            }
            if (!usable) {
                continue
            }

            for (interfaceAddress in networkInterface.interfaceAddresses) {
                val address = interfaceAddress.address as? Inet4Address ?: continue
                if (!isUsableLocalIPv4(address)) {
                    continue
                }

                val prefixLength = interfaceAddress.networkPrefixLength
                    .toInt()
                    .coerceIn(0, 32)
                if (prefixLength > 0 && sameIPv4Subnet(address, peer, prefixLength)) {
                    return address
                }
            }
        }

        return null
    }

    private fun adaptiveLinkIdentityKey(): String? {
        if (transportMode == TransportMode.USB) {
            return null
        }

        val peerAddress = source?.address as? Inet4Address ?: return null
        val localAddress = (networkBindAddress as? Inet4Address)
            ?: (localAddressForPeer(peerAddress) as? Inet4Address)
            ?: return null
        val networkIdentity = adaptiveNetworkIdentity(localAddress, peerAddress) ?: return null
        val accessPoint = wifiAccessPointIdentity()?.let { "ap:${linkKeyPart(it)}" }
            ?: "ap:unknown"
        val transport = transportMode.name.lowercase(Locale.US)
        val mode = profile.mode.name.lowercase(Locale.US)
        val format = "fmt:${profile.sampleRate}:${profile.channels}:${profile.packetTimeMs}"

        val rawKey = listOf(
            "v$ADAPTIVE_LINK_MEMORY_VERSION",
            transport,
            accessPoint,
            "if:${linkKeyPart(networkIdentity.interfaceName)}",
            "desc:${linkKeyPart(networkIdentity.interfaceDescription)}",
            "local:${networkIdentity.localSubnet}",
            "peer:${networkIdentity.peerSubnet}",
            "host:${peerAddress.hostAddress}",
            mode,
            format
        ).joinToString("|")
        return "link:${sha256Hex(rawKey)}"
    }

    private fun adaptiveNetworkIdentity(
        localAddress: Inet4Address,
        peerAddress: Inet4Address
    ): AdaptiveNetworkIdentity? {
        val interfaces = try {
            NetworkInterface.getNetworkInterfaces()
        } catch (_: SocketException) {
            null
        } ?: return null

        for (networkInterface in Collections.list(interfaces)) {
            val usable = try {
                networkInterface.isUp && !networkInterface.isLoopback
            } catch (_: SocketException) {
                false
            }
            if (!usable) {
                continue
            }

            for (interfaceAddress in networkInterface.interfaceAddresses) {
                val address = interfaceAddress.address as? Inet4Address ?: continue
                if (address != localAddress) {
                    continue
                }

                val prefixLength = interfaceAddress.networkPrefixLength
                    .toInt()
                    .coerceIn(0, 32)
                return AdaptiveNetworkIdentity(
                    interfaceName = networkInterface.name,
                    interfaceDescription = networkInterface.displayName ?: networkInterface.name,
                    prefixLength = prefixLength,
                    localSubnet = ipv4SubnetLabel(localAddress, prefixLength),
                    peerSubnet = ipv4SubnetLabel(peerAddress, prefixLength)
                )
            }
        }

        return null
    }

    @Suppress("DEPRECATION")
    private fun wifiAccessPointIdentity(): String? {
        if (transportMode != TransportMode.WIFI) {
            return null
        }

        val wifiManager = context.applicationContext
            .getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return null
        val connectionInfo = wifiManager.connectionInfo ?: return null
        val ssid = connectionInfo.ssid
            ?.trim('"')
            ?.takeIf { it.isNotBlank() && it != "<unknown ssid>" }
        val bssid = connectionInfo.bssid
            ?.takeIf {
                it.isNotBlank() &&
                    it != "02:00:00:00:00:00" &&
                    it != "00:00:00:00:00:00"
            }

        return listOfNotNull(ssid, bssid).takeIf { it.isNotEmpty() }?.joinToString("@")
    }

    private fun isUsableLocalIPv4(address: Inet4Address): Boolean {
        return !address.isAnyLocalAddress &&
            !address.isLoopbackAddress &&
            !address.isLinkLocalAddress
    }

    private fun sameIPv4Subnet(
        localAddress: Inet4Address,
        peerAddress: Inet4Address,
        prefixLength: Int
    ): Boolean {
        val mask = if (prefixLength == 0) 0 else -1 shl (32 - prefixLength)
        return (ipv4ToInt(localAddress) and mask) == (ipv4ToInt(peerAddress) and mask)
    }

    private fun ipv4ToInt(address: Inet4Address): Int {
        val bytes = address.address
        return ((bytes[0].toInt() and 0xFF) shl 24) or
            ((bytes[1].toInt() and 0xFF) shl 16) or
            ((bytes[2].toInt() and 0xFF) shl 8) or
            (bytes[3].toInt() and 0xFF)
    }

    private fun ipv4SubnetLabel(address: Inet4Address, prefixLength: Int): String {
        val mask = if (prefixLength == 0) 0 else -1 shl (32 - prefixLength)
        val network = ipv4ToInt(address) and mask
        return "${ipv4IntToString(network)}/$prefixLength"
    }

    private fun ipv4IntToString(value: Int): String {
        return listOf(
            (value ushr 24) and 0xFF,
            (value ushr 16) and 0xFF,
            (value ushr 8) and 0xFF,
            value and 0xFF
        ).joinToString(".")
    }

    private fun linkKeyPart(value: String): String {
        return value.lowercase(Locale.US).replace(Regex("[^a-z0-9.:-]+"), "_")
    }

    private fun sha256Hex(value: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { byte ->
            String.format(Locale.US, "%02x", byte.toInt() and 0xFF)
        }
    }

    private fun DatagramSocket.applyLowDelaySocketOptions() {
        try {
            trafficClass = LOW_DELAY_TRAFFIC_CLASS
        } catch (_: SocketException) {
        }
        try {
            receiveBufferSize = UDP_BUFFER_BYTES
            sendBufferSize = UDP_BUFFER_BYTES
        } catch (_: SocketException) {
        }
    }

    private fun startSenderControl() {
        if (senderControlRunning) {
            return
        }
        if (transportMode == TransportMode.USB) {
            senderControlRunning = true
            senderControlThread = Thread({
                usbSenderControlLoop()
            }, "AudioBridgeUsbSenderControl").apply {
                isDaemon = true
                start()
            }
            return
        }
        if (socket == null || socket?.isClosed == true) {
            socket = openSenderSocket()
        }

        senderControlRunning = true
        senderControlThread = Thread({
            senderControlLoop()
        }, "AudioBridgeSenderControl").apply {
            isDaemon = true
            start()
        }
    }

    private fun stopSenderControl() {
        stopSenderCapture()
        senderControlRunning = false
        socket?.close()
        senderControlThread?.join(800)
        senderControlThread = null
        socket = null
        senderPeer = null
        lastHeartbeatSentAtMs = 0L
        closeUsbConnection()
        resetRemoteMetrics()
    }

    private fun senderControlLoop() {
        val activeSocket = socket ?: return
        val buffer = ByteArray(SUBSCRIBE_MAX_BYTES)

        while (senderControlRunning) {
            try {
                val packet = DatagramPacket(buffer, buffer.size)
                activeSocket.receive(packet)
                if (!isSubscribeMessage(packet.data, packet.length)) {
                    continue
                }

                val message = String(packet.data, packet.offset, packet.length, Charsets.UTF_8)
                updateRemoteMetrics(message)
                val peer = SenderPeer(
                    endpoint = InetSocketAddress(packet.address, packet.port),
                    sessionId = parseSessionId(message)
                )
                senderPeer = peer
                maybeSendHeartbeat(activeSocket, peer)
            } catch (_: SocketTimeoutException) {
                continue
            } catch (_: SocketException) {
                if (senderControlRunning) {
                    senderControlRunning = false
                }
            }
        }
    }

    private fun usbSenderControlLoop() {
        val frameHeader = ByteArray(USB_FRAME_HEADER_BYTES)

        while (senderControlRunning) {
            if (!ensureUsbAccessoryConnection()) {
                sleepUsbRetry()
                continue
            }

            val input = synchronized(usbIoLock) { usbInput } ?: run {
                sleepUsbRetry()
                continue
            }

            try {
                readFully(input, frameHeader)
                val length = ByteBuffer.wrap(frameHeader)
                    .order(ByteOrder.LITTLE_ENDIAN)
                    .int
                if (length <= 0 || length > 64 * 1024) {
                    closeUsbConnection()
                    continue
                }

                val payload = ByteArray(length)
                readFully(input, payload)
                if (isSubscribeMessage(payload, payload.size)) {
                    val message = String(payload, Charsets.UTF_8)
                    updateRemoteMetrics(message)
                    val peer = SenderPeer(
                        endpoint = null,
                        sessionId = parseSessionId(message)
                    )
                    senderPeer = peer
                    maybeSendUsbHeartbeat(peer)
                }
            } catch (_: EOFException) {
                closeUsbConnection()
            } catch (_: IOException) {
                closeUsbConnection()
            } catch (_: SecurityException) {
                closeUsbConnection()
            }
        }
    }

    private fun maybeSendHeartbeat(activeSocket: DatagramSocket, peer: SenderPeer) {
        val endpoint = peer.endpoint ?: return
        val sessionId = peer.sessionId ?: return
        val now = SystemClock.elapsedRealtime()
        if (now - lastHeartbeatSentAtMs < HEARTBEAT_INTERVAL_MS) {
            return
        }

        val packet = heartbeatPacket(sessionId, now)
        try {
            activeSocket.send(
                DatagramPacket(packet, packet.size, endpoint.address, endpoint.port)
            )
            lastHeartbeatSentAtMs = now
        } catch (_: IOException) {
            droppedPackets.incrementAndGet()
        } catch (_: SecurityException) {
            droppedPackets.incrementAndGet()
        }
    }

    private fun maybeSendUsbHeartbeat(peer: SenderPeer) {
        val sessionId = peer.sessionId ?: return
        val now = SystemClock.elapsedRealtime()
        if (now - lastHeartbeatSentAtMs < HEARTBEAT_INTERVAL_MS) {
            return
        }

        lastHeartbeatSentAtMs = now
        sendUsbFrame(heartbeatPacket(sessionId, now))
    }

    private fun heartbeatPacket(sessionId: Long, sendTimeMs: Long): ByteArray {
        return ByteBuffer.allocate(PACKET_V5_HEADER_BYTES)
            .order(ByteOrder.LITTLE_ENDIAN)
            .putInt(PACKET_V5_MAGIC)
            .putInt(senderSequence)
            .putInt(0)
            .putShort(0)
            .putShort(0)
            .putShort(CODEC_PCM.toShort())
            .putShort(PACKET_KIND_HEARTBEAT.toShort())
            .putInt(0)
            .putLong(sendTimeMs)
            .putLong(0)
            .putLong(0)
            .putInt(profile.playbackBufferMs.coerceIn(minLatencyMs(), MAX_LATENCY_MS))
            .putInt(receiverOptionsFor(profile))
            .putLong(sessionId)
            .array()
    }

    private fun parseSessionId(message: String): Long? {
        if ((parseLongMetric(message, "protocol") ?: 0L) < 5L) {
            return null
        }
        return parseLongMetric(message, "sessionId")?.takeIf { it > 0L }
    }

    private fun nextSessionId(): Long {
        while (true) {
            val candidate = sessionRandom.nextLong() and Long.MAX_VALUE
            if (candidate != 0L) {
                return candidate
            }
        }
    }

    private fun startSenderStream() {
        if (running) {
            return
        }
        if (!microphoneAllowed()) {
            error("Microphone permission is required for Android sender mode.")
        }
        if (transportMode != TransportMode.USB && (socket == null || socket?.isClosed == true)) {
            socket = openSenderSocket()
        }
        startSenderControl()

        running = true
        droppedPackets.set(0)
        lostPackets.set(0)
        trimCount.set(0)
        senderSequence = 0
        resetSenderPacketizer()
        captureThread = Thread({
            senderCaptureLoop()
        }, "AudioBridgeSenderCapture").apply {
            isDaemon = true
            start()
        }
    }

    private fun stopSenderCapture() {
        running = false
        try {
            audioRecord?.stop()
        } catch (_: IllegalStateException) {
        }
        captureThread?.join(800)
        captureThread = null
        releaseAudioRecord()
        releaseOpusEncoder()
        resetSenderPacketizer()
    }

    private fun senderCaptureLoop() {
        try {
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        } catch (_: SecurityException) {
            Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
        }

        val capture = createAudioRecord() ?: run {
            running = false
            return
        }
        audioRecord = capture.record
        currentInputSampleRate = capture.sampleRate
        currentSampleRate = capture.sampleRate
        currentChannels = profile.channels.coerceIn(1, 2)

        val packetFrames = profile.packetFrames(sampleRate = capture.sampleRate)
        val readBuffer = ShortArray(packetFrames * capture.channels)
        try {
            capture.record.startRecording()
            while (running) {
                val readSamples = capture.record.read(
                    readBuffer,
                    0,
                    readBuffer.size,
                    AudioRecord.READ_BLOCKING
                )
                if (readSamples > 0) {
                    appendCapturedPcm(readBuffer, readSamples, capture.sampleRate, capture.channels)
                } else if (readSamples == AudioRecord.ERROR_INVALID_OPERATION) {
                    break
                }
            }
        } catch (_: IllegalStateException) {
            running = false
        } finally {
            releaseAudioRecord()
        }
    }

    @SuppressLint("MissingPermission")
    private fun createAudioRecord(): SenderAudioCapture? {
        val requestedSampleRate = if (profile.codec == CODEC_OPUS) {
            OPUS_SAMPLE_RATE
        } else {
            profile.sampleRate.coerceIn(8000, MAX_OUTPUT_SAMPLE_RATE)
        }
        val requestedChannels = profile.channels.coerceIn(1, 2)
        val sampleRates = if (profile.codec == CODEC_OPUS) {
            listOf(OPUS_SAMPLE_RATE)
        } else {
            listOf(requestedSampleRate, 48000, 44100)
                .distinct()
                .filter { it in 8000..MAX_OUTPUT_SAMPLE_RATE }
        }
        val channelCounts = listOf(requestedChannels, 1).distinct()

        for (sampleRate in sampleRates) {
            for (channels in channelCounts) {
                val channelMask = inputChannelMask(channels)
                val minBufferSize = AudioRecord.getMinBufferSize(
                    sampleRate,
                    channelMask,
                    AudioFormat.ENCODING_PCM_16BIT
                )
                if (minBufferSize <= 0) {
                    continue
                }

                val bytesPerFrame = channels * 2
                val packetBytes = profile.packetFrames(sampleRate = sampleRate) * bytesPerFrame
                val captureBufferBytes = max(
                    minBufferSize,
                    max(packetBytes * 4, latencyBytes(sampleRate, channels, profile.captureBufferMs))
                )
                val format = AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(sampleRate)
                    .setChannelMask(channelMask)
                    .build()
                val record = try {
                    AudioRecord.Builder()
                        .setAudioSource(MediaRecorder.AudioSource.MIC)
                        .setAudioFormat(format)
                        .setBufferSizeInBytes(captureBufferBytes)
                        .build()
                } catch (_: UnsupportedOperationException) {
                    null
                } catch (_: IllegalArgumentException) {
                    null
                }
                if (record?.state == AudioRecord.STATE_INITIALIZED) {
                    return SenderAudioCapture(record, sampleRate, channels, captureBufferBytes)
                }
                record?.release()
            }
        }

        return null
    }

    private fun appendCapturedPcm(
        data: ShortArray,
        sampleCount: Int,
        sampleRate: Int,
        channels: Int
    ) {
        val packetChannels = profile.channels.coerceIn(1, 2)
        val packetData: ShortArray
        val packetSampleCount: Int
        if (channels == packetChannels) {
            packetData = data
            packetSampleCount = sampleCount
        } else {
            val inputChannels = max(1, channels)
            val frameCount = sampleCount / inputChannels
            val remixed = ShortArray(frameCount * packetChannels)
            var input = 0
            var output = 0
            repeat(frameCount) {
                if (packetChannels == 1) {
                    var sum = 0
                    repeat(inputChannels) { channel ->
                        sum += data[input + channel].toInt()
                    }
                    remixed[output] = (sum / inputChannels).toShort()
                } else {
                    repeat(packetChannels) { channel ->
                        remixed[output + channel] =
                            data[input + min(channel, inputChannels - 1)]
                    }
                }
                input += inputChannels
                output += packetChannels
            }
            packetData = remixed
            packetSampleCount = remixed.size
        }

        val codecId = senderCodecId()
        signalLevel = if (muted) {
            0.0
        } else {
            pcmPeakLevel(packetData, packetSampleCount)
        }
        val packetTimeMs = profile.packetTimeMs.coerceIn(1, 12)
        if (
            packetizerSampleRate != sampleRate ||
            packetizerChannels != packetChannels ||
            packetizerPacketTimeMs != packetTimeMs ||
            packetizerCodecId != codecId
        ) {
            resetSenderPacketizer(sampleRate, packetChannels, packetTimeMs, codecId)
        }

        ensurePacketizerCapacity(packetizerPendingSamples + packetSampleCount)
        packetData.copyInto(
            destination = packetizerPendingPcm,
            destinationOffset = packetizerPendingSamples,
            startIndex = 0,
            endIndex = packetSampleCount
        )
        packetizerPendingSamples += packetSampleCount

        val maxFrames = maxPacketFrames(codecId, packetChannels)
        while (running) {
            val pendingFrames = packetizerPendingSamples / packetChannels
            val frames = nextSenderPacketFrameCount(sampleRate, packetTimeMs, maxFrames)
            if (pendingFrames < frames) {
                break
            }

            val chunkSamples = frames * packetChannels
            val chunk = packetizerPendingPcm.copyOfRange(0, chunkSamples)
            sendCapturedPacket(
                encodeAudioPacket(chunk, packetChannels, codecId),
                sampleRate,
                packetChannels
            )

            val remainingSamples = packetizerPendingSamples - chunkSamples
            if (remainingSamples > 0) {
                packetizerPendingPcm.copyInto(
                    destination = packetizerPendingPcm,
                    destinationOffset = 0,
                    startIndex = chunkSamples,
                    endIndex = packetizerPendingSamples
                )
            }
            packetizerPendingSamples = remainingSamples
            packetizerSentFrames += frames
            packetizerPacketCount += 1L
        }
    }

    private fun sendCapturedPacket(
        encoded: EncodedAudioPacket,
        sampleRate: Int,
        channels: Int
    ) {
        if (encoded.payload.isEmpty()) {
            return
        }

        val sendTimeMs = SystemClock.elapsedRealtime()
        val receiverClockEcho = remoteReceiverClockEcho
        val hasFreshReceiverTime =
            receiverClockEcho.receiverTimeMs > 0L &&
                receiverClockEcho.receivedAtSenderTimeMs > 0L &&
                sendTimeMs - receiverClockEcho.receivedAtSenderTimeMs < 3000L
        val echoedReceiverTimeMs = if (hasFreshReceiverTime) {
            receiverClockEcho.receiverTimeMs
        } else {
            0L
        }
        val echoReceivedAtSenderTimeMs = if (hasFreshReceiverTime) {
            receiverClockEcho.receivedAtSenderTimeMs
        } else {
            0L
        }

        val peer = senderPeer
        val sessionId = peer?.sessionId
        val headerBytes = if (sessionId == null) {
            PACKET_V4_HEADER_BYTES
        } else {
            PACKET_V5_HEADER_BYTES
        }
        val packetBuilder = ByteBuffer.allocate(headerBytes + encoded.payload.size)
            .order(ByteOrder.LITTLE_ENDIAN)
            .putInt(if (sessionId == null) PACKET_V4_MAGIC else PACKET_V5_MAGIC)
            .putInt(senderSequence++)
            .putInt(sampleRate)
            .putShort(channels.toShort())
            .putShort(encoded.flags.toShort())
            .putShort(encoded.codecId.toShort())
            .putShort(PACKET_KIND_AUDIO.toShort())
            .putInt(encoded.decodedFrameCount)
            .putLong(sendTimeMs)
            .putLong(echoedReceiverTimeMs)
            .putLong(echoReceivedAtSenderTimeMs)
            .putInt(profile.playbackBufferMs.coerceIn(minLatencyMs(), MAX_LATENCY_MS))
            .putInt(receiverOptionsFor(profile))
        if (sessionId != null) {
            packetBuilder.putLong(sessionId)
        }
        val packet = packetBuilder.put(encoded.payload).array()

        if (transportMode == TransportMode.USB) {
            sendUsbFrame(packet)
            return
        }

        val activeSocket = socket ?: return
        val endpoint = peer?.endpoint ?: return
        try {
            activeSocket.send(DatagramPacket(packet, packet.size, endpoint.address, endpoint.port))
        } catch (_: IOException) {
            droppedPackets.incrementAndGet()
        } catch (_: SecurityException) {
            droppedPackets.incrementAndGet()
        }
    }

    private fun encodeAudioPacket(
        pcm: ShortArray,
        channels: Int,
        codecId: Int
    ): EncodedAudioPacket {
        val flags = if (muted) PACKET_FLAG_MUTED else 0
        val decodedFrameCount = if (channels <= 0) 0 else pcm.size / channels

        return when (codecId) {
            CODEC_OPUS -> EncodedAudioPacket(
                codecId = CODEC_OPUS,
                payload = encodeOpusPayload(pcm, channels),
                decodedFrameCount = decodedFrameCount,
                flags = flags
            )
            CODEC_AAC -> {
                val payload = encodeAacPayload(pcm, channels)
                val encodedFrameCount = aacPayloadFrameCount(payload)
                EncodedAudioPacket(
                    codecId = CODEC_AAC,
                    payload = payload,
                    decodedFrameCount = if (encodedFrameCount > 0) {
                        encodedFrameCount * AAC_SAMPLES_PER_FRAME
                    } else {
                        decodedFrameCount
                    },
                    flags = flags
                )
            }
            CODEC_G711_MU_LAW -> EncodedAudioPacket(
                codecId = CODEC_G711_MU_LAW,
                payload = encodeG711Payload(pcm, muLaw = true),
                decodedFrameCount = decodedFrameCount,
                flags = flags
            )
            CODEC_G711_A_LAW -> EncodedAudioPacket(
                codecId = CODEC_G711_A_LAW,
                payload = encodeG711Payload(pcm, muLaw = false),
                decodedFrameCount = decodedFrameCount,
                flags = flags
            )
            CODEC_IMA_ADPCM -> EncodedAudioPacket(
                codecId = CODEC_IMA_ADPCM,
                payload = encodeImaAdpcmPayload(pcm, channels),
                decodedFrameCount = decodedFrameCount,
                flags = flags
            )
            else -> EncodedAudioPacket(
                codecId = CODEC_PCM,
                payload = encodePcmPayload(pcm),
                decodedFrameCount = decodedFrameCount,
                flags = flags
            )
        }
    }

    private fun encodeOpusPayload(pcm: ShortArray, channels: Int): ByteArray {
        val channelCount = channels.coerceIn(1, 2)
        val frameSamples = if (channelCount <= 0) 0 else pcm.size / channelCount
        if (!isSupportedOpusFrameSamples(frameSamples)) {
            return ByteArray(0)
        }

        val encoder = ensureOpusEncoder(channelCount) ?: return ByteArray(0)
        val input = ShortArray(pcm.size)
        for (index in pcm.indices) {
            input[index] = scaledSample(pcm[index])
        }
        return opusNative.encode(encoder, input, frameSamples) ?: ByteArray(0)
    }

    private fun ensureOpusEncoder(channels: Int): Long? {
        val channelCount = channels.coerceIn(1, 2)
        val bitrateBps = profile.bitrateKbps.coerceIn(64, 256) * 1000
        val lowDelay = shouldUseLowDelayOpus()
        if (
            opusEncoderHandle != 0L &&
            opusEncoderChannels == channelCount &&
            opusEncoderBitrateBps == bitrateBps &&
            opusEncoderLowDelay == lowDelay
        ) {
            return opusEncoderHandle
        }

        releaseOpusEncoder()

        val nextHandle = opusNative.createEncoder(channelCount, bitrateBps, lowDelay)
        if (nextHandle == 0L) {
            return null
        }
        opusEncoderHandle = nextHandle
        opusEncoderChannels = channelCount
        opusEncoderBitrateBps = bitrateBps
        opusEncoderLowDelay = lowDelay
        return opusEncoderHandle
    }

    private fun shouldUseLowDelayOpus(): Boolean {
        return profile.mode == AudioMode.GAMING ||
            profile.packetTimeMs <= 2 ||
            profile.playbackBufferMs <= 28
    }

    private fun encodeAacPayload(pcm: ShortArray, channels: Int): ByteArray {
        val sampleRate = packetizerSampleRate.takeIf { it > 0 } ?: profile.sampleRate
        val channelCount = channels.coerceIn(1, 2)
        val encoder = ensureAacEncoder(
            sampleRate = sampleRate,
            channels = channelCount,
            bitrateKbps = profile.bitrateKbps
        ) ?: return ByteArray(0)

        val inputIndex = try {
            encoder.dequeueInputBuffer(5000)
        } catch (_: IllegalStateException) {
            releaseAacEncoder()
            return ByteArray(0)
        }
        if (inputIndex < 0) {
            return drainAacEncoder(encoder, sampleRate, channelCount)
        }

        try {
            val inputBuffer = encoder.getInputBuffer(inputIndex) ?: return ByteArray(0)
            inputBuffer.clear()
            val inputSize = pcm.size * 2
            if (inputBuffer.remaining() < inputSize) {
                releaseAacEncoder()
                return ByteArray(0)
            }
            for (sample in pcm) {
                val scaled = scaledSample(sample).toInt()
                inputBuffer.put((scaled and 0xFF).toByte())
                inputBuffer.put(((scaled ushr 8) and 0xFF).toByte())
            }
            val frameCount = if (channelCount <= 0) 0 else pcm.size / channelCount
            val presentationTimeUs =
                aacEncoderSubmittedFrames * 1_000_000L / max(1, aacEncoderSampleRate)
            encoder.queueInputBuffer(
                inputIndex,
                0,
                inputSize,
                presentationTimeUs,
                0
            )
            aacEncoderSubmittedFrames += frameCount
        } catch (_: IllegalStateException) {
            releaseAacEncoder()
            return ByteArray(0)
        } catch (_: IllegalArgumentException) {
            releaseAacEncoder()
            return ByteArray(0)
        }

        return drainAacEncoder(encoder, sampleRate, channelCount)
    }

    private fun ensureAacEncoder(
        sampleRate: Int,
        channels: Int,
        bitrateKbps: Int
    ): MediaCodec? {
        if (aacSampleRateIndex(sampleRate) == null) {
            return null
        }

        val channelCount = channels.coerceIn(1, 2)
        val bitrateBps = bitrateKbps.coerceIn(96, 192) * 1000
        if (
            aacEncoder != null &&
            aacEncoderSampleRate == sampleRate &&
            aacEncoderChannels == channelCount &&
            aacEncoderBitrateBps == bitrateBps
        ) {
            return aacEncoder
        }

        releaseAacEncoder()

        return try {
            val format = MediaFormat.createAudioFormat(
                AAC_MIME_TYPE,
                sampleRate,
                channelCount
            ).apply {
                setInteger(
                    MediaFormat.KEY_AAC_PROFILE,
                    MediaCodecInfo.CodecProfileLevel.AACObjectLC
                )
                setInteger(MediaFormat.KEY_BIT_RATE, bitrateBps)
                setInteger(
                    MediaFormat.KEY_MAX_INPUT_SIZE,
                    AAC_SAMPLES_PER_FRAME * channelCount * 2
                )
            }
            MediaCodec.createEncoderByType(AAC_MIME_TYPE).apply {
                configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                start()
                aacEncoder = this
                aacEncoderSampleRate = sampleRate
                aacEncoderChannels = channelCount
                aacEncoderBitrateBps = bitrateBps
                aacEncoderSubmittedFrames = 0L
            }
        } catch (_: IOException) {
            releaseAacEncoder()
            null
        } catch (_: IllegalArgumentException) {
            releaseAacEncoder()
            null
        } catch (_: IllegalStateException) {
            releaseAacEncoder()
            null
        }
    }

    private fun drainAacEncoder(
        encoder: MediaCodec,
        sampleRate: Int,
        channels: Int
    ): ByteArray {
        val output = ArrayList<ByteArray>()
        val info = MediaCodec.BufferInfo()
        while (true) {
            val outputIndex = try {
                encoder.dequeueOutputBuffer(info, 0)
            } catch (_: IllegalStateException) {
                releaseAacEncoder()
                return ByteArray(0)
            }

            if (outputIndex >= 0) {
                val outputBuffer = encoder.getOutputBuffer(outputIndex)
                if (
                    outputBuffer != null &&
                    info.size > 0 &&
                    (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0
                ) {
                    val frame = ByteArray(info.size + 7)
                    writeAdtsHeader(
                        frame = frame,
                        payloadSize = info.size,
                        sampleRate = sampleRate,
                        channels = channels
                    )
                    outputBuffer.position(info.offset)
                    outputBuffer.limit(info.offset + info.size)
                    outputBuffer.get(frame, 7, info.size)
                    output.add(frame)
                }
                encoder.releaseOutputBuffer(outputIndex, false)
            } else if (outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                continue
            } else {
                break
            }
        }

        val totalBytes = output.sumOf { it.size }
        if (totalBytes == 0) {
            return ByteArray(0)
        }
        val merged = ByteArray(totalBytes)
        var offset = 0
        for (frame in output) {
            frame.copyInto(merged, offset)
            offset += frame.size
        }
        return merged
    }

    private fun writeAdtsHeader(
        frame: ByteArray,
        payloadSize: Int,
        sampleRate: Int,
        channels: Int
    ) {
        val profile = 2
        val sampleRateIndex = aacSampleRateIndex(sampleRate) ?: 3
        val channelConfig = channels.coerceIn(1, 2)
        val frameLength = payloadSize + 7

        frame[0] = 0xFF.toByte()
        frame[1] = 0xF1.toByte()
        frame[2] = (((profile - 1) shl 6) or (sampleRateIndex shl 2) or (channelConfig shr 2)).toByte()
        frame[3] = (((channelConfig and 0x03) shl 6) or (frameLength shr 11)).toByte()
        frame[4] = ((frameLength and 0x7FF) shr 3).toByte()
        frame[5] = (((frameLength and 0x07) shl 5) or 0x1F).toByte()
        frame[6] = 0xFC.toByte()
    }

    private fun aacSampleRateIndex(sampleRate: Int): Int? {
        return when (sampleRate) {
            96000 -> 0
            88200 -> 1
            64000 -> 2
            48000 -> 3
            44100 -> 4
            32000 -> 5
            24000 -> 6
            22050 -> 7
            16000 -> 8
            12000 -> 9
            11025 -> 10
            8000 -> 11
            7350 -> 12
            else -> null
        }
    }

    private fun aacPayloadFrameCount(payload: ByteArray): Int {
        var offset = 0
        var count = 0
        while (offset + 7 <= payload.size) {
            val frameSize = adtsFrameSize(payload, offset, payload.size - offset)
            if (frameSize <= 0 || offset + frameSize > payload.size) {
                break
            }
            count += 1
            offset += frameSize
        }
        return count
    }

    private fun adtsFrameSize(data: ByteArray, offset: Int, available: Int): Int {
        if (available < 7) {
            return -1
        }

        val syncHigh = data[offset].toInt() and 0xFF
        val syncLow = data[offset + 1].toInt() and 0xF0
        if (syncHigh != 0xFF || syncLow != 0xF0) {
            return -1
        }

        return ((data[offset + 3].toInt() and 0x03) shl 11) or
            ((data[offset + 4].toInt() and 0xFF) shl 3) or
            ((data[offset + 5].toInt() and 0xE0) shr 5)
    }

    private fun adtsHeaderSize(data: ByteArray, offset: Int, available: Int): Int {
        if (available < 7) {
            return 7
        }
        val protectionAbsent = (data[offset + 1].toInt() and 0x01) != 0
        return if (protectionAbsent) 7 else 9
    }

    private fun findNextAdtsFrameOffset(data: ByteArray, startOffset: Int, endOffset: Int): Int {
        var offset = startOffset
        while (offset + 7 <= endOffset) {
            val frameSize = adtsFrameSize(data, offset, endOffset - offset)
            if (frameSize > 0 && offset + frameSize <= endOffset) {
                return offset
            }
            offset += 1
        }
        return -1
    }

    private fun encodePcmPayload(pcm: ShortArray): ByteArray {
        val output = ByteArray(pcm.size * 2)
        var offset = 0
        for (sample in pcm) {
            writePcm16(output, offset, scaledSample(sample))
            offset += 2
        }
        return output
    }

    private fun encodeG711Payload(pcm: ShortArray, muLaw: Boolean): ByteArray {
        val output = ByteArray(pcm.size)
        for (index in pcm.indices) {
            val sample = scaledSample(pcm[index])
            output[index] = if (muLaw) {
                linearToMuLaw(sample).toByte()
            } else {
                linearToALaw(sample).toByte()
            }
        }
        return output
    }

    private fun encodeImaAdpcmPayload(pcm: ShortArray, channels: Int): ByteArray {
        val channelCount = max(1, channels)
        val states = MutableList(channelCount) { channel ->
            ImaAdpcmEncodeState(
                predictor = if (channel < pcm.size) scaledSample(pcm[channel]).toInt() else 0,
                stepIndex = 0
            )
        }
        val output = ByteArray(channelCount * 4 + (pcm.size + 1) / 2)
        var outputOffset = 0
        for (state in states) {
            val predictor = state.predictor
            output[outputOffset++] = predictor.toByte()
            output[outputOffset++] = (predictor shr 8).toByte()
            output[outputOffset++] = state.stepIndex.toByte()
            output[outputOffset++] = 0
        }

        var pendingNibble = 0
        var hasPendingNibble = false
        for (index in pcm.indices) {
            val channel = index % channelCount
            val nibble = encodeImaNibble(scaledSample(pcm[index]), states[channel])
            if (!hasPendingNibble) {
                pendingNibble = nibble
                hasPendingNibble = true
            } else {
                output[outputOffset++] = (pendingNibble or (nibble shl 4)).toByte()
                hasPendingNibble = false
            }
        }
        if (hasPendingNibble) {
            output[outputOffset++] = pendingNibble.toByte()
        }

        return output.copyOf(outputOffset)
    }

    private fun scaledSample(sample: Short): Short {
        if (muted) {
            return 0
        }
        return (sample * volume)
            .roundToInt()
            .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
            .toShort()
    }

    private fun updateRemoteMetrics(message: String) {
        val receivedAt = SystemClock.elapsedRealtime()
        parseLongMetric(message, "receiverTimeMs")?.let {
            remoteReceiverClockEcho = RemoteReceiverClockEcho(
                receiverTimeMs = it,
                receivedAtSenderTimeMs = receivedAt
            )
        }

        var hasMetric = false
        parseStringMetric(message, "platform")?.let {
            remotePlatform = it
            hasMetric = true
        }
        parseStringMetric(message, "supportedCodecs")?.let { codecList ->
            remoteSupportedCodecs = codecList
                .split(',')
                .map { it.trim() }
                .filter { it.isNotEmpty() }
            hasMetric = true
        }
        parseDoubleMetric(message, "outputLatencyMs")?.let {
            remoteOutputLatencyMs = it
            hasMetric = true
        }
        parseDoubleMetric(message, "audioLatencyMs")?.let {
            remoteAudioLatencyMs = it
            hasMetric = true
        }
        parseDoubleMetric(message, "networkLatencyMs")?.let {
            remoteNetworkLatencyMs = it
            hasMetric = true
        }
        parseDoubleMetric(message, "signalLevel")?.let {
            remoteSignalLevel = it.coerceIn(0.0, 1.0)
            hasMetric = true
        }
        parseLongMetric(message, "queuedFrames")?.let {
            remoteQueuedFrames.set(it)
            hasMetric = true
        }
        parseLongMetric(message, "bufferSizeFrames")?.let {
            remoteBufferSizeFrames.set(it)
            hasMetric = true
        }
        parseLongMetric(message, "targetBufferFrames")?.let {
            remoteTargetBufferFrames.set(it)
            hasMetric = true
        }
        parseLongMetric(message, "adaptivePlaybackBufferMs")?.let {
            remoteAdaptivePlaybackBufferMs.set(it)
            hasMetric = true
        }
        parseLongMetric(message, "adaptiveMaxPlaybackBufferMs")?.let {
            remoteAdaptiveMaxPlaybackBufferMs.set(it)
            hasMetric = true
        }
        parseLongMetric(message, "adaptiveLimitReached")?.let {
            remoteAdaptiveLimitReached.set(if (it > 0L) 1L else 0L)
            hasMetric = true
        }
        parseLongMetric(message, "adaptiveUnderrunsInWindow")?.let {
            remoteAdaptiveUnderrunsInWindow.set(it)
            hasMetric = true
        }
        parseLongMetric(message, "adaptiveUnderrunsInBurst")?.let {
            remoteAdaptiveUnderrunsInBurst.set(it)
            hasMetric = true
        }
        parseLongMetric(message, "adaptiveLowQueueSamples")?.let {
            remoteAdaptiveLowQueueSamples.set(it)
            hasMetric = true
        }
        parseLongMetric(message, "playbackQueueFillPercent")?.let {
            remotePlaybackQueueFillPercent.set(it)
            hasMetric = true
        }
        parseLongMetric(message, "underrunCount")?.let {
            remoteUnderrunCount.set(it)
            hasMetric = true
        }
        parseLongMetric(message, "droppedPacketCount")?.let {
            remoteDroppedPacketCount.set(it)
            hasMetric = true
        }
        parseLongMetric(message, "lostPacketCount")?.let {
            remoteLostPacketCount.set(it)
            hasMetric = true
        }
        parseLongMetric(message, "trimCount")?.let {
            remoteTrimCount.set(it)
            hasMetric = true
        }
        if (hasMetric) {
            remoteMetricsReceivedAtMs.set(receivedAt)
        }
    }

    private fun resetRemoteMetrics() {
        remoteOutputLatencyMs = Double.NaN
        remoteAudioLatencyMs = Double.NaN
        remoteNetworkLatencyMs = Double.NaN
        remoteSignalLevel = 0.0
        remotePlatform = null
        remoteSupportedCodecs = emptyList()
        remoteQueuedFrames.set(0)
        remoteBufferSizeFrames.set(0)
        remoteTargetBufferFrames.set(0)
        remoteAdaptivePlaybackBufferMs.set(0)
        remoteAdaptiveMaxPlaybackBufferMs.set(0)
        remoteAdaptiveLimitReached.set(0)
        remoteAdaptiveUnderrunsInWindow.set(0)
        remoteAdaptiveUnderrunsInBurst.set(0)
        remoteAdaptiveLowQueueSamples.set(0)
        remotePlaybackQueueFillPercent.set(0)
        remoteUnderrunCount.set(0)
        remoteDroppedPacketCount.set(0)
        remoteLostPacketCount.set(0)
        remoteTrimCount.set(0)
        remoteMetricsReceivedAtMs.set(0)
        remoteReceiverClockEcho = RemoteReceiverClockEcho()
    }

    private fun ensurePacketizerCapacity(requiredSamples: Int) {
        if (packetizerPendingPcm.size >= requiredSamples) {
            return
        }
        var nextSize = max(256, packetizerPendingPcm.size)
        while (nextSize < requiredSamples) {
            nextSize *= 2
        }
        packetizerPendingPcm = packetizerPendingPcm.copyOf(nextSize)
    }

    private fun nextSenderPacketFrameCount(
        sampleRate: Int,
        packetTimeMs: Int,
        maxFrames: Int
    ): Int {
        val targetFrames = sampleRate.toDouble() * packetTimeMs / 1000.0
        if (packetizerCodecId == CODEC_OPUS) {
            return min(opusFrameSamplesForPacketTime(packetTimeMs), maxFrames)
        }
        if (packetizerCodecId == CODEC_AAC) {
            return AAC_SAMPLES_PER_FRAME
        }
        if (targetFrames >= maxFrames) {
            return maxFrames
        }

        val scheduledTotalFrames = ((packetizerPacketCount + 1) * targetFrames).roundToLong()
        val nextFrames = if (scheduledTotalFrames > packetizerSentFrames) {
            scheduledTotalFrames - packetizerSentFrames
        } else {
            1L
        }
        return nextFrames.toInt().coerceIn(1, maxFrames)
    }

    private fun maxPacketFrames(codecId: Int, channels: Int): Int {
        if (codecId == CODEC_OPUS) {
            return OPUS_LONG_FRAME_SAMPLES
        }
        if (codecId == CODEC_AAC) {
            return AAC_SAMPLES_PER_FRAME
        }

        val channelCount = max(1, channels)
        val encodedBytesPerFrame = when (codecId) {
            CODEC_G711_MU_LAW,
            CODEC_G711_A_LAW -> channelCount
            CODEC_IMA_ADPCM -> max(1, (channelCount + 1) / 2)
            else -> channelCount * 2
        }
        val overhead = if (codecId == CODEC_IMA_ADPCM) channelCount * 4 else 0
        val maxPayloadBytes = MAX_PACKET_BYTES - PACKET_V4_HEADER_BYTES - overhead
        return max(1, maxPayloadBytes / max(1, encodedBytesPerFrame))
    }

    private fun opusFrameSamplesForPacketTime(packetTimeMs: Int): Int {
        return if (packetTimeMs <= 2) {
            OPUS_LOW_FRAME_SAMPLES
        } else if (packetTimeMs <= OPUS_SHORT_FRAME_MS) {
            OPUS_SHORT_FRAME_SAMPLES
        } else {
            OPUS_LONG_FRAME_SAMPLES
        }
    }

    private fun isSupportedOpusFrameSamples(frameSamples: Int): Boolean {
        return frameSamples == OPUS_LOW_FRAME_SAMPLES ||
            frameSamples == OPUS_SHORT_FRAME_SAMPLES ||
            frameSamples == OPUS_LONG_FRAME_SAMPLES
    }

    private fun senderCodecId(): Int {
        return when (profile.codec) {
            CODEC_OPUS,
            CODEC_AAC,
            CODEC_G711_MU_LAW,
            CODEC_G711_A_LAW,
            CODEC_IMA_ADPCM -> profile.codec
            else -> CODEC_PCM
        }
    }

    private fun resetSenderPacketizer(
        sampleRate: Int = 0,
        channels: Int = 0,
        packetTimeMs: Int = 0,
        codecId: Int = CODEC_PCM
    ) {
        packetizerPendingPcm = ShortArray(0)
        packetizerPendingSamples = 0
        packetizerSentFrames = 0L
        packetizerPacketCount = 0L
        packetizerSampleRate = sampleRate
        packetizerChannels = channels
        packetizerPacketTimeMs = packetTimeMs
        packetizerCodecId = codecId
        releaseAacEncoder()
        if (codecId != CODEC_OPUS) {
            releaseOpusEncoder()
        }
    }

    private fun releaseAudioRecord() {
        audioRecord?.run {
            try {
                stop()
            } catch (_: IllegalStateException) {
            }
            release()
        }
        audioRecord = null
        currentInputSampleRate = 0
        currentSampleRate = 0
        currentChannels = 0
    }

    private fun microphoneAllowed(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun receiveLoop() {
        try {
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        } catch (_: SecurityException) {
            Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
        }

        val buffer = ByteArray(1500)
        var lastSubscribeAt = 0L

        while (running) {
            val activeSocket = socket
            if (activeSocket == null) {
                reopenReceiverSocket(null)
                continue
            }
            val now = SystemClock.elapsedRealtime()
            if (now - lastSubscribeAt > SUBSCRIBE_INTERVAL_MS) {
                if (sendSubscribe(activeSocket)) {
                    lastSubscribeAt = now
                } else {
                    reopenReceiverSocket(activeSocket)
                    continue
                }
            }

            try {
                val packet = DatagramPacket(buffer, buffer.size)
                activeSocket.receive(packet)
                try {
                    handleAudioPacket(packet.data, packet.length)
                } catch (error: RuntimeException) {
                    droppedPackets.incrementAndGet()
                    Log.w(LOG_TAG, "dropped malformed audio packet length=${packet.length}", error)
                }
            } catch (_: SocketTimeoutException) {
                continue
            } catch (_: SocketException) {
                if (running) {
                    reopenReceiverSocket(activeSocket)
                }
            } catch (error: IOException) {
                if (running) {
                    droppedPackets.incrementAndGet()
                    Log.w(LOG_TAG, "audio receive failed; reopening socket", error)
                    reopenReceiverSocket(activeSocket)
                }
            } catch (error: SecurityException) {
                if (running) {
                    droppedPackets.incrementAndGet()
                    Log.w(LOG_TAG, "audio receive blocked; reopening socket", error)
                    reopenReceiverSocket(activeSocket)
                }
            }
        }
    }

    private fun usbReceiveLoop() {
        Log.i(LOG_TAG, "usbReceiveLoop started")
        try {
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        } catch (_: SecurityException) {
            Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
        }

        var lastSubscribeAt = 0L
        val frameHeader = ByteArray(USB_FRAME_HEADER_BYTES)

        while (running) {
            if (!ensureUsbAccessoryConnection()) {
                sleepUsbRetry()
                continue
            }

            val input = synchronized(usbIoLock) { usbInput } ?: run {
                sleepUsbRetry()
                continue
            }
            val output = synchronized(usbIoLock) { usbOutput } ?: run {
                sleepUsbRetry()
                continue
            }

            val now = SystemClock.elapsedRealtime()
            if (now - lastSubscribeAt > SUBSCRIBE_INTERVAL_MS) {
                sendUsbSubscribe(output)
                lastSubscribeAt = now
            }

            try {
                readFully(input, frameHeader)
                val length = ByteBuffer.wrap(frameHeader)
                    .order(ByteOrder.LITTLE_ENDIAN)
                    .int
                if (length <= 0 || length > 64 * 1024) {
                    closeUsbConnection()
                    continue
                }

                val payload = ByteArray(length)
                readFully(input, payload)
                usbFramesReceived += 1
                if (usbFramesReceived <= 5 || usbFramesReceived % 1000L == 0L) {
                    Log.i(LOG_TAG, "received USB frame #$usbFramesReceived length=$length")
                }
                handleAudioPacket(payload, payload.size)
            } catch (_: EOFException) {
                Log.w(LOG_TAG, "usbReceiveLoop EOF; closing accessory")
                closeUsbConnection()
            } catch (_: IOException) {
                Log.w(LOG_TAG, "usbReceiveLoop IOException; closing accessory")
                closeUsbConnection()
            } catch (_: SecurityException) {
                Log.w(LOG_TAG, "usbReceiveLoop SecurityException; closing accessory")
                closeUsbConnection()
            }
        }
        Log.i(LOG_TAG, "usbReceiveLoop stopped")
    }

    fun findAudioBridgeAccessory(): UsbAccessory? {
        val usbManager = context.getSystemService(UsbManager::class.java)
        return usbManager.accessoryList?.firstOrNull { accessory ->
            accessory.manufacturer == ACCESSORY_MANUFACTURER &&
                accessory.model == ACCESSORY_MODEL
        }
    }

    private fun ensureUsbAccessoryConnection(): Boolean {
        synchronized(usbIoLock) {
            if (usbConnection != null && usbInput != null && usbOutput != null) {
                return true
            }
        }

        val accessory = findAudioBridgeAccessory() ?: return false
        val usbManager = context.getSystemService(UsbManager::class.java)
        if (!usbManager.hasPermission(accessory)) {
            Log.w(LOG_TAG, "no permission for AudioBridge accessory")
            return false
        }

        val connection = try {
            usbManager.openAccessory(accessory)
        } catch (error: IOException) {
            Log.w(LOG_TAG, "openAccessory IOException", error)
            null
        } catch (error: SecurityException) {
            Log.w(LOG_TAG, "openAccessory SecurityException", error)
            null
        } ?: return false

        val input = FileInputStream(connection.fileDescriptor)
        val output = FileOutputStream(connection.fileDescriptor)
        var closeNewConnection = false
        synchronized(usbIoLock) {
            if (usbConnection == null) {
                usbConnection = connection
                usbInput = input
                usbOutput = output
                Log.i(LOG_TAG, "opened AudioBridge accessory connection")
            } else {
                closeNewConnection = true
            }
        }

        if (closeNewConnection) {
            try {
                input.close()
            } catch (_: IOException) {
            }
            try {
                output.close()
            } catch (_: IOException) {
            }
            try {
                connection.close()
            } catch (_: IOException) {
            }
        }
        return true
    }

    private fun closeUsbConnection() {
        var input: FileInputStream? = null
        var output: FileOutputStream? = null
        var connection: ParcelFileDescriptor? = null
        synchronized(usbIoLock) {
            input = usbInput
            output = usbOutput
            connection = usbConnection
            usbInput = null
            usbOutput = null
            usbConnection = null
        }

        if (input != null || output != null || connection != null) {
            Log.i(LOG_TAG, "closed AudioBridge accessory connection")
        }

        try {
            input?.close()
        } catch (_: IOException) {
        }
        try {
            output?.close()
        } catch (_: IOException) {
        }
        try {
            connection?.close()
        } catch (_: IOException) {
        }
    }

    private fun sleepUsbRetry() {
        try {
            Thread.sleep(120)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    private fun sendSubscribe(activeSocket: DatagramSocket): Boolean {
        val activeSource = source ?: return false
        val payload = subscribePayload()
        return try {
            activeSocket.send(
                DatagramPacket(payload, payload.size, activeSource.address, activeSource.port)
            )
            true
        } catch (_: IOException) {
            droppedPackets.incrementAndGet()
            false
        } catch (_: SecurityException) {
            droppedPackets.incrementAndGet()
            false
        } catch (_: RuntimeException) {
            droppedPackets.incrementAndGet()
            false
        }
    }

    private fun sendUsbSubscribe(output: OutputStream) {
        val payload = subscribePayload()
        val header = ByteBuffer.allocate(USB_FRAME_HEADER_BYTES)
            .order(ByteOrder.LITTLE_ENDIAN)
            .putInt(payload.size)
            .array()
        try {
            synchronized(usbWriteLock) {
                output.write(header)
                output.flush()
                output.write(payload)
                output.flush()
            }
            usbSubscribeFramesSent += 1
            if (usbSubscribeFramesSent <= 5 || usbSubscribeFramesSent % 60L == 0L) {
                Log.i(
                    LOG_TAG,
                    "sent USB subscribe #$usbSubscribeFramesSent bytes=${header.size + payload.size}"
                )
            }
        } catch (_: IOException) {
            Log.w(LOG_TAG, "sendUsbSubscribe IOException")
            droppedPackets.incrementAndGet()
            closeUsbConnection()
        } catch (_: SecurityException) {
            Log.w(LOG_TAG, "sendUsbSubscribe SecurityException")
            droppedPackets.incrementAndGet()
            closeUsbConnection()
        }
    }

    private fun sendUsbFrame(payload: ByteArray) {
        if (!ensureUsbAccessoryConnection()) {
            return
        }
        val output = synchronized(usbIoLock) { usbOutput } ?: return
        val header = ByteBuffer.allocate(USB_FRAME_HEADER_BYTES)
            .order(ByteOrder.LITTLE_ENDIAN)
            .putInt(payload.size)
            .array()
        try {
            synchronized(usbWriteLock) {
                output.write(header)
                output.flush()
                output.write(payload)
                output.flush()
            }
        } catch (_: IOException) {
            droppedPackets.incrementAndGet()
            closeUsbConnection()
        } catch (_: SecurityException) {
            droppedPackets.incrementAndGet()
            closeUsbConnection()
        }
    }

    private fun readFully(input: InputStream, buffer: ByteArray) {
        var offset = 0
        while (offset < buffer.size) {
            val read = input.read(buffer, offset, buffer.size - offset)
            if (read < 0) {
                throw EOFException()
            }
            offset += read
        }
    }

    private fun subscribePayload(): ByteArray {
        val metrics = getMetrics()
        val latency = (metrics["outputLatencyMs"] as? Number)?.toDouble()
        val queuedFrames = (metrics["queuedFrames"] as? Number)?.toLong()
        val bufferSizeFrames = (metrics["bufferSizeFrames"] as? Number)?.toLong()
        val targetBufferFrames = (metrics["targetBufferFrames"] as? Number)?.toLong()
        val adaptivePlaybackBufferMs =
            (metrics["adaptivePlaybackBufferMs"] as? Number)?.toInt()
        val adaptiveMaxPlaybackBufferMs =
            (metrics["adaptiveMaxPlaybackBufferMs"] as? Number)?.toInt()
        val adaptiveLimitReached = metrics["adaptiveLimitReached"] as? Boolean
        val adaptiveUnderrunsInWindow =
            (metrics["adaptiveUnderrunsInWindow"] as? Number)?.toInt()
        val adaptiveUnderrunsInBurst =
            (metrics["adaptiveUnderrunsInBurst"] as? Number)?.toInt()
        val adaptiveLowQueueSamples =
            (metrics["adaptiveLowQueueSamples"] as? Number)?.toInt()
        val playbackQueueFillPercent =
            (metrics["playbackQueueFillPercent"] as? Number)?.toInt()
        val underruns = (metrics["underrunCount"] as? Number)?.toInt()
        val audioLatency = (metrics["audioLatencyMs"] as? Number)?.toDouble()
        val networkLatency = (metrics["networkLatencyMs"] as? Number)?.toDouble()
        val signalLevel = (metrics["signalLevel"] as? Number)?.toDouble()

        val message = buildString {
            append(SUBSCRIBE_MESSAGE)
            append(" protocol=5 sessionId=")
            append(receiverSessionId)
            append(" platform=android")
            append(" supportedCodecs=")
            append(RECEIVER_SUPPORTED_CODECS)
            append(" receiverTimeMs=")
            append(SystemClock.elapsedRealtime())
            if (audioLatency != null) {
                append(" audioLatencyMs=")
                append(String.format(Locale.US, "%.2f", audioLatency))
            }
            if (latency != null) {
                append(" outputLatencyMs=")
                append(String.format(Locale.US, "%.2f", latency))
            }
            if (networkLatency != null) {
                append(" networkLatencyMs=")
                append(String.format(Locale.US, "%.2f", networkLatency))
            }
            if (signalLevel != null) {
                append(" signalLevel=")
                append(String.format(Locale.US, "%.4f", signalLevel.coerceIn(0.0, 1.0)))
            }
            if (queuedFrames != null) {
                append(" queuedFrames=")
                append(queuedFrames)
            }
            if (bufferSizeFrames != null) {
                append(" bufferSizeFrames=")
                append(bufferSizeFrames)
            }
            if (targetBufferFrames != null) {
                append(" targetBufferFrames=")
                append(targetBufferFrames)
            }
            if (adaptivePlaybackBufferMs != null) {
                append(" adaptivePlaybackBufferMs=")
                append(adaptivePlaybackBufferMs)
            }
            if (adaptiveMaxPlaybackBufferMs != null) {
                append(" adaptiveMaxPlaybackBufferMs=")
                append(adaptiveMaxPlaybackBufferMs)
            }
            if (adaptiveLimitReached != null) {
                append(" adaptiveLimitReached=")
                append(if (adaptiveLimitReached) 1 else 0)
            }
            if (adaptiveUnderrunsInWindow != null) {
                append(" adaptiveUnderrunsInWindow=")
                append(adaptiveUnderrunsInWindow)
            }
            if (adaptiveUnderrunsInBurst != null) {
                append(" adaptiveUnderrunsInBurst=")
                append(adaptiveUnderrunsInBurst)
            }
            if (adaptiveLowQueueSamples != null) {
                append(" adaptiveLowQueueSamples=")
                append(adaptiveLowQueueSamples)
            }
            if (playbackQueueFillPercent != null) {
                append(" playbackQueueFillPercent=")
                append(playbackQueueFillPercent)
            }
            if (underruns != null) {
                append(" underrunCount=")
                append(underruns)
            }
            append(" droppedPacketCount=")
            append(droppedPackets.get())
            append(" lostPacketCount=")
            append(lostPackets.get())
            append(" trimCount=")
            append(trimCount.get())
        }
        return message.toByteArray(Charsets.UTF_8)
    }

    private fun handleAudioPacket(data: ByteArray, length: Int) {
        if (length <= PACKET_HEADER_BYTES) {
            Log.w(LOG_TAG, "drop short audio packet length=$length")
            return
        }

        val header = ByteBuffer.wrap(data, 0, PACKET_HEADER_BYTES).order(ByteOrder.LITTLE_ENDIAN)
        val magic = header.int
        if (!acceptsLegacyPacket(sessionProtocolActive) && magic != PACKET_V5_MAGIC) {
            return
        }
        when (magic) {
            PACKET_MAGIC -> {
                logAudioPacketHandled(magic, length)
                handlePcmV1Packet(header, data, length)
            }
            PACKET_V2_MAGIC -> {
                logAudioPacketHandled(magic, length)
                handlePacketV2(data, length)
            }
            PACKET_V3_MAGIC -> {
                logAudioPacketHandled(magic, length)
                handlePacketV3(data, length)
            }
            PACKET_V4_MAGIC -> {
                logAudioPacketHandled(magic, length)
                handlePacketV4(data, length)
            }
            PACKET_V5_MAGIC -> {
                logAudioPacketHandled(magic, length)
                handlePacketV5(data, length)
            }
            else -> {
                unknownUsbPacketCount += 1
                if (unknownUsbPacketCount <= 5 || unknownUsbPacketCount % 1000L == 0L) {
                    Log.w(
                        LOG_TAG,
                        "drop packet with unknown magic=$magic length=$length count=$unknownUsbPacketCount"
                    )
                }
                return
            }
        }
    }

    private fun logAudioPacketHandled(magic: Int, length: Int) {
        usbAudioPacketsHandled += 1
        if (usbAudioPacketsHandled <= 5 || usbAudioPacketsHandled % 1000L == 0L) {
            Log.i(LOG_TAG, "handle audio packet #$usbAudioPacketsHandled magic=$magic length=$length")
        }
    }

    private fun handlePcmV1Packet(header: ByteBuffer, data: ByteArray, length: Int) {
        val sequence = header.int.toLong() and 0xFFFF_FFFFL
        val sampleRate = header.int
        val channels = header.short.toInt() and 0xFFFF
        val flags = header.short.toInt() and 0xFFFF
        updatePacketLoss(sequence)

        val payloadSize = length - PACKET_HEADER_BYTES
        writePcmPayload(
            data = data,
            offset = PACKET_HEADER_BYTES,
            payloadSize = payloadSize,
            sequence = sequence,
            sampleRate = sampleRate,
            channels = channels,
            packetMuted = (flags and PACKET_FLAG_MUTED) != 0,
            senderSendTimeMs = 0,
            echoedReceiverTimeMs = 0,
            echoReceivedAtSenderTimeMs = 0
        )
    }

    private fun writeAudioPayload(
        data: ByteArray,
        offset: Int,
        payloadSize: Int,
        sequence: Long,
        codecId: Int,
        decodedFrameCount: Int,
        sampleRate: Int,
        channels: Int,
        packetMuted: Boolean,
        senderSendTimeMs: Long,
        echoedReceiverTimeMs: Long,
        echoReceivedAtSenderTimeMs: Long
    ) {
        if (codecId != lastCodecId) {
            lastCodecId = codecId
        }

        val expectedPcmBytes = decodedFrameCount * max(1, channels) * 2
        val pcmPayload = when (codecId) {
            CODEC_PCM -> data.copyOfRange(offset, offset + payloadSize)
            CODEC_OPUS -> decodeOpusPayload(data, offset, payloadSize, channels)
            CODEC_AAC -> decodeAacPayload(data, offset, payloadSize, sampleRate, channels)
            CODEC_G711_MU_LAW -> decodeG711MuLawPayload(data, offset, payloadSize)
            CODEC_G711_A_LAW -> decodeG711ALawPayload(data, offset, payloadSize)
            CODEC_IMA_ADPCM -> decodeImaAdpcmPayload(data, offset, payloadSize, channels)
            else -> null
        }
        if (pcmPayload == null) {
            droppedPackets.incrementAndGet()
            return
        }
        if (pcmPayload.isEmpty()) {
            return
        }
        val trimmedPcmPayload = if (
            expectedPcmBytes > 0 &&
            expectedPcmBytes <= pcmPayload.size
        ) {
            pcmPayload.copyOf(expectedPcmBytes)
        } else {
            pcmPayload
        }

        writePcmPayload(
            data = trimmedPcmPayload,
            offset = 0,
            payloadSize = trimmedPcmPayload.size,
            sequence = sequence,
            sampleRate = if (codecId == CODEC_OPUS) OPUS_SAMPLE_RATE else sampleRate,
            channels = channels,
            packetMuted = packetMuted,
            senderSendTimeMs = senderSendTimeMs,
            echoedReceiverTimeMs = echoedReceiverTimeMs,
            echoReceivedAtSenderTimeMs = echoReceivedAtSenderTimeMs
        )
    }

    private fun handlePacketV2(data: ByteArray, length: Int) {
        if (length <= PACKET_V2_HEADER_BYTES) {
            return
        }

        val header = ByteBuffer.wrap(data, 0, PACKET_V2_HEADER_BYTES).order(ByteOrder.LITTLE_ENDIAN)
        header.int
        val sequence = header.int.toLong() and 0xFFFF_FFFFL
        val sampleRate = header.int
        val channels = header.short.toInt() and 0xFFFF
        val flags = header.short.toInt() and 0xFFFF
        val codecId = header.short.toInt() and 0xFFFF
        val packetKind = header.short.toInt() and 0xFFFF
        header.int
        updatePacketLoss(sequence)

        if (packetKind != PACKET_KIND_AUDIO) {
            droppedPackets.incrementAndGet()
            return
        }

        writeAudioPayload(
            data = data,
            offset = PACKET_V2_HEADER_BYTES,
            payloadSize = length - PACKET_V2_HEADER_BYTES,
            sequence = sequence,
            codecId = codecId,
            decodedFrameCount = 0,
            sampleRate = sampleRate,
            channels = channels,
            packetMuted = (flags and PACKET_FLAG_MUTED) != 0,
            senderSendTimeMs = 0,
            echoedReceiverTimeMs = 0,
            echoReceivedAtSenderTimeMs = 0
        )
    }

    private fun handlePacketV3(data: ByteArray, length: Int) {
        if (length <= PACKET_V3_HEADER_BYTES) {
            return
        }

        val header = ByteBuffer.wrap(data, 0, PACKET_V3_HEADER_BYTES).order(ByteOrder.LITTLE_ENDIAN)
        header.int
        val sequence = header.int.toLong() and 0xFFFF_FFFFL
        val sampleRate = header.int
        val channels = header.short.toInt() and 0xFFFF
        val flags = header.short.toInt() and 0xFFFF
        val codecId = header.short.toInt() and 0xFFFF
        val packetKind = header.short.toInt() and 0xFFFF
        header.int
        val senderSendTimeMs = header.long
        val echoedReceiverTimeMs = header.long
        val echoReceivedAtSenderTimeMs = header.long
        updatePacketLoss(sequence)

        if (packetKind != PACKET_KIND_AUDIO) {
            droppedPackets.incrementAndGet()
            return
        }

        writeAudioPayload(
            data = data,
            offset = PACKET_V3_HEADER_BYTES,
            payloadSize = length - PACKET_V3_HEADER_BYTES,
            sequence = sequence,
            codecId = codecId,
            decodedFrameCount = 0,
            sampleRate = sampleRate,
            channels = channels,
            packetMuted = (flags and PACKET_FLAG_MUTED) != 0,
            senderSendTimeMs = senderSendTimeMs,
            echoedReceiverTimeMs = echoedReceiverTimeMs,
            echoReceivedAtSenderTimeMs = echoReceivedAtSenderTimeMs
        )
    }

    private fun handlePacketV4(data: ByteArray, length: Int) {
        if (sessionProtocolActive || length <= PACKET_V4_HEADER_BYTES) {
            return
        }

        val header = ByteBuffer.wrap(data, 0, PACKET_V4_HEADER_BYTES).order(ByteOrder.LITTLE_ENDIAN)
        header.int
        val sequence = header.int.toLong() and 0xFFFF_FFFFL
        val sampleRate = header.int
        val channels = header.short.toInt() and 0xFFFF
        val flags = header.short.toInt() and 0xFFFF
        val codecId = header.short.toInt() and 0xFFFF
        val packetKind = header.short.toInt() and 0xFFFF
        val decodedFrameCount = header.int
        val senderSendTimeMs = header.long
        val echoedReceiverTimeMs = header.long
        val echoReceivedAtSenderTimeMs = header.long
        val playbackBufferMs = header.int.coerceIn(minLatencyMs(), MAX_LATENCY_MS)
        val receiverOptions = header.int
        updatePacketLoss(sequence)

        if (packetKind != PACKET_KIND_AUDIO) {
            droppedPackets.incrementAndGet()
            return
        }

        handleSessionAudioPayload(
            data = data,
            length = length,
            payloadOffset = PACKET_V4_HEADER_BYTES,
            sequence = sequence,
            sampleRate = sampleRate,
            channels = channels,
            flags = flags,
            codecId = codecId,
            decodedFrameCount = decodedFrameCount,
            senderSendTimeMs = senderSendTimeMs,
            echoedReceiverTimeMs = echoedReceiverTimeMs,
            echoReceivedAtSenderTimeMs = echoReceivedAtSenderTimeMs,
            playbackBufferMs = playbackBufferMs,
            receiverOptions = receiverOptions
        )
    }

    private fun handlePacketV5(data: ByteArray, length: Int) {
        if (length < PACKET_V5_HEADER_BYTES) {
            return
        }

        val header = ByteBuffer.wrap(data, 0, PACKET_V5_HEADER_BYTES)
            .order(ByteOrder.LITTLE_ENDIAN)
        header.int
        val sequence = header.int.toLong() and 0xFFFF_FFFFL
        val sampleRate = header.int
        val channels = header.short.toInt() and 0xFFFF
        val flags = header.short.toInt() and 0xFFFF
        val codecId = header.short.toInt() and 0xFFFF
        val packetKind = header.short.toInt() and 0xFFFF
        val decodedFrameCount = header.int
        val senderSendTimeMs = header.long
        val echoedReceiverTimeMs = header.long
        val echoReceivedAtSenderTimeMs = header.long
        val playbackBufferMs = header.int.coerceIn(minLatencyMs(), MAX_LATENCY_MS)
        val receiverOptions = header.int
        val sessionId = header.long

        if (!acceptsSessionPacket(receiverSessionId, sessionId)) {
            droppedPackets.incrementAndGet()
            return
        }

        sessionProtocolActive = true
        lastPeerPacketReceivedAtMs = SystemClock.elapsedRealtime()
        if (packetKind == PACKET_KIND_HEARTBEAT) {
            return
        }
        if (packetKind != PACKET_KIND_AUDIO || length <= PACKET_V5_HEADER_BYTES) {
            droppedPackets.incrementAndGet()
            return
        }

        updatePacketLoss(sequence)
        handleSessionAudioPayload(
            data = data,
            length = length,
            payloadOffset = PACKET_V5_HEADER_BYTES,
            sequence = sequence,
            sampleRate = sampleRate,
            channels = channels,
            flags = flags,
            codecId = codecId,
            decodedFrameCount = decodedFrameCount,
            senderSendTimeMs = senderSendTimeMs,
            echoedReceiverTimeMs = echoedReceiverTimeMs,
            echoReceivedAtSenderTimeMs = echoReceivedAtSenderTimeMs,
            playbackBufferMs = playbackBufferMs,
            receiverOptions = receiverOptions
        )
    }

    private fun handleSessionAudioPayload(
        data: ByteArray,
        length: Int,
        payloadOffset: Int,
        sequence: Long,
        sampleRate: Int,
        channels: Int,
        flags: Int,
        codecId: Int,
        decodedFrameCount: Int,
        senderSendTimeMs: Long,
        echoedReceiverTimeMs: Long,
        echoReceivedAtSenderTimeMs: Long,
        playbackBufferMs: Int,
        receiverOptions: Int
    ) {
        val receiverAdaptiveBuffer =
            (receiverOptions and RECEIVER_OPTION_ADAPTIVE_BUFFER) != 0
        val mode = AudioMode.fromPacketId(
            (receiverOptions and RECEIVER_OPTION_MODE_MASK) shr RECEIVER_OPTION_MODE_SHIFT
        )
        val adaptiveBufferCapMs =
            (receiverOptions and RECEIVER_OPTION_CUSTOM_CAP_MASK) shr
                RECEIVER_OPTION_CUSTOM_CAP_SHIFT
        val activeBitrateKbps =
            (receiverOptions ushr RECEIVER_OPTION_BITRATE_SHIFT) and
                RECEIVER_OPTION_BITRATE_MASK

        val adaptivePolicyChanged =
            profile.mode != mode ||
                profile.adaptiveBufferCapMs != adaptiveBufferCapMs ||
                profile.receiverAdaptiveBuffer != receiverAdaptiveBuffer
        val playbackTargetChanged = profile.playbackBufferMs != playbackBufferMs
        val bitrateChanged =
            activeBitrateKbps > 0 && profile.bitrateKbps != activeBitrateKbps
        if (adaptivePolicyChanged || playbackTargetChanged || bitrateChanged) {
            val previousAdaptiveBufferMs = adaptivePlaybackBufferMs
            profile = profile.copy(
                mode = mode,
                bitrateKbps = if (activeBitrateKbps > 0) {
                    activeBitrateKbps
                } else {
                    profile.bitrateKbps
                },
                playbackBufferMs = playbackBufferMs,
                adaptiveBufferCapMs = adaptiveBufferCapMs,
                receiverAdaptiveBuffer = receiverAdaptiveBuffer
            )
            if (adaptivePolicyChanged || playbackTargetChanged) {
                if (adaptivePolicyChanged) {
                    resetAdaptiveDelayTracker()
                }
                refreshAdaptiveLinkMemoryKey()
                val rememberedBufferMs = initialAdaptivePlaybackBufferMs()
                val now = SystemClock.elapsedRealtime()
                lastAdaptiveBufferRelaxAtMs = now
                lastPlaybackPressureAtMs = now
                if (audioTrack != null) {
                    val nextMaxBufferMs = adaptiveMaxPlaybackBufferMs(playbackBufferMs)
                    val nextBufferMs = when {
                        !receiverAdaptiveBuffer -> playbackBufferMs
                        adaptivePolicyChanged &&
                            shouldStartAdaptiveBufferAtRequested(playbackBufferMs) ->
                            playbackBufferMs
                        playbackBufferMs > previousAdaptiveBufferMs -> max(
                            playbackBufferMs,
                            rememberedBufferMs
                        )
                        previousAdaptiveBufferMs > nextMaxBufferMs -> nextMaxBufferMs
                        else -> max(previousAdaptiveBufferMs, rememberedBufferMs)
                    }
                    updateAdaptivePlaybackBuffer(
                        outputSampleRateForPlayback(sampleRate),
                        nextBufferMs,
                        remember = false
                    )
                } else {
                    adaptivePlaybackBufferMs = rememberedBufferMs
                }
            }
        }
        writeAudioPayload(
            data = data,
            offset = payloadOffset,
            payloadSize = length - payloadOffset,
            sequence = sequence,
            codecId = codecId,
            decodedFrameCount = decodedFrameCount,
            sampleRate = sampleRate,
            channels = channels,
            packetMuted = (flags and PACKET_FLAG_MUTED) != 0,
            senderSendTimeMs = senderSendTimeMs,
            echoedReceiverTimeMs = echoedReceiverTimeMs,
            echoReceivedAtSenderTimeMs = echoReceivedAtSenderTimeMs
        )
    }

    private fun writePcmPayload(
        data: ByteArray,
        offset: Int,
        payloadSize: Int,
        sequence: Long,
        sampleRate: Int,
        channels: Int,
        packetMuted: Boolean,
        senderSendTimeMs: Long,
        echoedReceiverTimeMs: Long,
        echoReceivedAtSenderTimeMs: Long
    ) {
        if (sampleRate <= 0 || channels <= 0 || payloadSize <= 0) {
            droppedPackets.incrementAndGet()
            return
        }

        val bytesPerFrame = max(1, channels) * 2
        val payloadFrames = payloadSize / bytesPerFrame
        val usablePayloadSize = payloadFrames * bytesPerFrame
        if (payloadFrames <= 0) {
            droppedPackets.incrementAndGet()
            return
        }

        val playbackSampleRate = outputSampleRateForPlayback(sampleRate)
        if (
            audioTrack != null &&
            (sampleRate != currentInputSampleRate || channels != currentChannels)
        ) {
            releaseAudioTrack()
        }

        val playbackPayload: ByteArray
        val playbackPayloadOffset: Int
        val playbackPayloadSize: Int
        if (sampleRate == playbackSampleRate) {
            resetPcmReformatter(sampleRate, channels, playbackSampleRate)
            playbackPayload = data
            playbackPayloadOffset = offset
            playbackPayloadSize = usablePayloadSize
        } else {
            playbackPayload = reformatPcmForPlayback(
                data = data,
                offset = offset,
                payloadSize = usablePayloadSize,
                inputSampleRate = sampleRate,
                channels = channels,
                outputSampleRate = playbackSampleRate
            ) ?: run {
                droppedPackets.incrementAndGet()
                return
            }
            if (playbackPayload.isEmpty()) {
                return
            }
            playbackPayloadOffset = 0
            playbackPayloadSize = playbackPayload.size
        }

        val track = ensureAudioTrack(playbackSampleRate, channels) ?: return
        currentInputSampleRate = sampleRate
        val playbackPayloadFrames = playbackPayloadSize / bytesPerFrame
        val packetReceivedAtReceiverMs = SystemClock.elapsedRealtime()
        val networkSampleMs = estimateNetworkLatencyMs(
            packetReceivedAtReceiverMs = packetReceivedAtReceiverMs,
            senderSendTimeMs = senderSendTimeMs,
            echoedReceiverTimeMs = echoedReceiverTimeMs,
            echoReceivedAtSenderTimeMs = echoReceivedAtSenderTimeMs
        )
        lastAudioPacketReceivedAtMs = packetReceivedAtReceiverMs
        lastPeerPacketReceivedAtMs = packetReceivedAtReceiverMs
        observeAdaptivePacketArrival(
            now = packetReceivedAtReceiverMs,
            sequence = sequence,
            sampleRate = sampleRate,
            packetFrames = payloadFrames
        )
        if (shouldDropForLatency(
                track,
                playbackSampleRate,
                playbackPayloadFrames,
                networkSampleMs
            )
        ) {
            return
        }

        val writtenBytes = if (muted || packetMuted) {
            signalLevel = 0.0
            writeSilence(track, playbackPayloadSize)
        } else {
            signalLevel = pcmPeakLevel(
                playbackPayload,
                playbackPayloadOffset,
                playbackPayloadSize
            )
            writePcmToTrack(
                track,
                playbackPayload,
                playbackPayloadOffset,
                playbackPayloadSize
            )
        }
        if (writtenBytes > 0) {
            val queuedAfterWrite = writtenFrames.addAndGet((writtenBytes / bytesPerFrame).toLong())
            updateAudioLatencyEstimate(
                track = track,
                sampleRate = playbackSampleRate,
                networkSampleMs = networkSampleMs
            )
            startPlaybackIfReady(track, queuedAfterWrite)
            if (writtenBytes < playbackPayloadSize) {
                droppedPackets.incrementAndGet()
            }
        } else {
            droppedPackets.incrementAndGet()
        }
    }

    private fun decodeOpusPayload(
        data: ByteArray,
        offset: Int,
        payloadSize: Int,
        channels: Int
    ): ByteArray? {
        val decoder = ensureOpusDecoder(channels).takeIf { it != 0L } ?: return null
        return opusNative.decode(decoder, data, offset, payloadSize)
    }

    private fun ensureOpusDecoder(channels: Int): Long {
        val channelCount = channels.coerceIn(1, 2)
        if (opusDecoderHandle != 0L && opusChannels == channelCount) {
            return opusDecoderHandle
        }

        releaseOpusDecoder()

        opusDecoderHandle = opusNative.createDecoder(channelCount)
        opusChannels = if (opusDecoderHandle == 0L) 0 else channelCount
        return opusDecoderHandle
    }

    private fun decodeAacPayload(
        data: ByteArray,
        offset: Int,
        payloadSize: Int,
        sampleRate: Int,
        channels: Int
    ): ByteArray? {
        val decoder = ensureAacDecoder(sampleRate, channels) ?: return null
        val output = ArrayList<ByteArray>()
        val endOffset = offset + payloadSize
        var readOffset = offset
        var foundAdtsFrame = false

        while (readOffset < endOffset) {
            val available = endOffset - readOffset
            val frameSize = adtsFrameSize(data, readOffset, available)
            val inputOffset: Int
            val inputSize: Int
            val advanceSize: Int
            when {
                frameSize > 0 && frameSize <= available -> {
                    foundAdtsFrame = true
                    val headerSize = adtsHeaderSize(data, readOffset, frameSize)
                    if (frameSize <= headerSize) {
                        break
                    }
                    inputOffset = readOffset + headerSize
                    inputSize = frameSize - headerSize
                    advanceSize = frameSize
                }
                foundAdtsFrame -> break
                else -> {
                    val nextFrameOffset = findNextAdtsFrameOffset(data, readOffset + 1, endOffset)
                    if (nextFrameOffset >= 0) {
                        readOffset = nextFrameOffset
                        continue
                    }
                    inputOffset = readOffset
                    inputSize = available
                    advanceSize = inputSize
                }
            }

            when (queueAacDecoderInput(decoder, data, inputOffset, inputSize)) {
                true -> Unit
                false -> return ByteArray(0)
                null -> return null
            }
            if (!drainAacDecoderOutput(decoder, output, AAC_CODEC_TIMEOUT_US)) {
                return null
            }

            readOffset += advanceSize
            if (frameSize <= 0) {
                break
            }
        }

        if (!drainAacDecoderOutput(decoder, output)) {
            return null
        }
        return mergeAacDecoderOutput(output)
    }

    private fun queueAacDecoderInput(
        decoder: MediaCodec,
        data: ByteArray,
        offset: Int,
        inputSize: Int
    ): Boolean? {
        val inputIndex = try {
            decoder.dequeueInputBuffer(AAC_CODEC_TIMEOUT_US)
        } catch (_: IllegalStateException) {
            releaseAacDecoder()
            return null
        }
        if (inputIndex < 0) {
            return false
        }

        return try {
            val inputBuffer = decoder.getInputBuffer(inputIndex) ?: return null
            inputBuffer.clear()
            if (inputBuffer.remaining() < inputSize) {
                return null
            }
            inputBuffer.put(data, offset, inputSize)
            decoder.queueInputBuffer(
                inputIndex,
                0,
                inputSize,
                SystemClock.elapsedRealtimeNanos() / 1000L,
                0
            )
            true
        } catch (_: IllegalStateException) {
            releaseAacDecoder()
            null
        } catch (_: IllegalArgumentException) {
            null
        }
    }

    private fun drainAacDecoderOutput(
        decoder: MediaCodec,
        output: MutableList<ByteArray>,
        timeoutUs: Long = 0L
    ): Boolean {
        val info = MediaCodec.BufferInfo()
        var nextTimeoutUs = timeoutUs
        while (true) {
            val outputIndex = try {
                decoder.dequeueOutputBuffer(info, nextTimeoutUs)
            } catch (_: IllegalStateException) {
                releaseAacDecoder()
                return false
            }
            nextTimeoutUs = 0L
            if (outputIndex >= 0) {
                val outputBuffer = decoder.getOutputBuffer(outputIndex)
                if (outputBuffer != null && info.size > 0) {
                    val pcm = ByteArray(info.size)
                    outputBuffer.position(info.offset)
                    outputBuffer.limit(info.offset + info.size)
                    outputBuffer.get(pcm)
                    output.add(pcm)
                }
                decoder.releaseOutputBuffer(outputIndex, false)
            } else if (outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                continue
            } else {
                break
            }
        }
        return true
    }

    private fun mergeAacDecoderOutput(output: List<ByteArray>): ByteArray {
        val totalBytes = output.sumOf { it.size }
        if (totalBytes == 0) {
            return ByteArray(0)
        }
        val merged = ByteArray(totalBytes)
        var writeOffset = 0
        for (chunk in output) {
            chunk.copyInto(merged, writeOffset)
            writeOffset += chunk.size
        }
        return merged
    }

    private fun ensureAacDecoder(sampleRate: Int, channels: Int): MediaCodec? {
        val channelCount = channels.coerceIn(1, 2)
        if (
            aacDecoder != null &&
            aacSampleRate == sampleRate &&
            aacChannels == channelCount
        ) {
            return aacDecoder
        }
        if (aacSampleRateIndex(sampleRate) == null) {
            return null
        }

        releaseAacDecoder()

        return try {
            val format = MediaFormat.createAudioFormat(
                AAC_MIME_TYPE,
                sampleRate,
                channelCount
            ).apply {
                setInteger(
                    MediaFormat.KEY_AAC_PROFILE,
                    MediaCodecInfo.CodecProfileLevel.AACObjectLC
                )
                setByteBuffer("csd-0", aacAudioSpecificConfig(sampleRate, channelCount))
            }
            MediaCodec.createDecoderByType(AAC_MIME_TYPE).apply {
                configure(format, null, null, 0)
                start()
                aacDecoder = this
                aacSampleRate = sampleRate
                aacChannels = channelCount
            }
        } catch (_: IOException) {
            releaseAacDecoder()
            null
        } catch (_: IllegalArgumentException) {
            releaseAacDecoder()
            null
        } catch (_: IllegalStateException) {
            releaseAacDecoder()
            null
        }
    }

    private fun aacAudioSpecificConfig(sampleRate: Int, channels: Int): ByteBuffer {
        val audioObjectType = 2
        val sampleRateIndex = aacSampleRateIndex(sampleRate) ?: 3
        val channelConfig = channels.coerceIn(1, 2)
        val config = ByteArray(2)
        config[0] = ((audioObjectType shl 3) or (sampleRateIndex shr 1)).toByte()
        config[1] = (((sampleRateIndex and 0x01) shl 7) or (channelConfig shl 3)).toByte()
        return ByteBuffer.wrap(config)
    }

    private fun updatePacketLoss(sequence: Long) {
        val previous = lastSequence
        if (previous >= 0) {
            val expected = (previous + 1L) and 0xFFFF_FFFFL
            if (sequence != expected) {
                val gap = (sequence - expected) and 0xFFFF_FFFFL
                if (gap in 1L until 0x8000_0000L) {
                    lostPackets.addAndGet(gap)
                } else {
                    droppedPackets.incrementAndGet()
                }
            }
        }
        lastSequence = sequence
    }

    private fun shouldDropForLatency(
        track: AudioTrack,
        sampleRate: Int,
        payloadFrames: Int,
        networkSampleMs: Double?
    ): Boolean {
        val queuedFrames = max(0L, writtenFrames.get() - playbackFrames(track))
        val targetFrames = adaptiveTargetFrames(sampleRate).toLong()
        val packetFrames = max(1L, payloadFrames.toLong())
        val softLimit = max(targetFrames + packetFrames * 2L, targetFrames * 3L / 2L)
        val hardLimit = max(targetFrames * 3L, targetFrames + sampleRate * 50L / 1000L)

        when (
            latencyRecoveryDecision(
                queuedFrames = queuedFrames,
                targetFrames = targetFrames,
                packetFrames = packetFrames,
                hardLimitFrames = hardLimit,
                sampleRate = sampleRate,
                networkSampleMs = networkSampleMs
            )
        ) {
            LatencyRecoveryDecision.ACCEPT -> {}
            LatencyRecoveryDecision.DROP -> {
                droppedPackets.incrementAndGet()
                return true
            }
            LatencyRecoveryDecision.TRIM_AND_ACCEPT -> {
                if (trimQueuedAudio(track)) {
                    return false
                }
                droppedPackets.incrementAndGet()
                return true
            }
            LatencyRecoveryDecision.TRIM_AND_DROP -> {
                trimQueuedAudio(track)
                droppedPackets.incrementAndGet()
                return true
            }
        }

        if (queuedFrames > softLimit) {
            droppedPackets.incrementAndGet()
            return true
        }
        return false
    }

    private fun writeSilence(track: AudioTrack, payloadSize: Int): Int {
        val output = ByteArray(payloadSize)
        return writePcmToTrack(track, output, 0, output.size)
    }

    private fun pcmPeakLevel(data: ByteArray, offset: Int, size: Int): Double {
        val end = min(data.size, offset + size)
        var cursor = offset
        var peak = 0
        while (cursor + 1 < end) {
            val sample = ((data[cursor].toInt() and 0xFF) or (data[cursor + 1].toInt() shl 8)).toShort()
            peak = max(peak, kotlin.math.abs(sample.toInt()))
            cursor += 2
        }
        return (peak / 32768.0).coerceIn(0.0, 1.0)
    }

    private fun pcmPeakLevel(data: ShortArray, sampleCount: Int): Double {
        val end = min(data.size, sampleCount)
        var peak = 0
        for (index in 0 until end) {
            peak = max(peak, kotlin.math.abs(data[index].toInt()))
        }
        return (peak / 32768.0).coerceIn(0.0, 1.0)
    }

    private fun outputSampleRateForPlayback(inputSampleRate: Int): Int {
        val nativeRate = nativeOutputSampleRate
        if (
            inputSampleRate == CD_SAMPLE_RATE &&
            nativeRate > 0 &&
            nativeRate != inputSampleRate
        ) {
            return nativeRate
        }

        return inputSampleRate
    }

    private fun reformatPcmForPlayback(
        data: ByteArray,
        offset: Int,
        payloadSize: Int,
        inputSampleRate: Int,
        channels: Int,
        outputSampleRate: Int
    ): ByteArray? {
        val channelCount = max(1, channels)
        val bytesPerFrame = channelCount * 2
        val inputFrames = payloadSize / bytesPerFrame
        if (inputFrames <= 0 || inputSampleRate <= 0 || outputSampleRate <= 0) {
            return ByteArray(0)
        }

        val usableBytes = inputFrames * bytesPerFrame
        if (inputSampleRate == outputSampleRate) {
            resetPcmReformatter(inputSampleRate, channelCount, outputSampleRate)
            return data.copyOfRange(offset, offset + usableBytes)
        }

        if (
            !pcmReformatterInitialized ||
            pcmReformatterInputSampleRate != inputSampleRate ||
            pcmReformatterChannels != channelCount ||
            pcmReformatterOutputSampleRate != outputSampleRate
        ) {
            resetPcmReformatter(inputSampleRate, channelCount, outputSampleRate)
        }

        val inputStart = pcmReformatterInputFramesConsumed.toDouble()
        val inputEnd = inputStart + inputFrames
        val sourceStep = inputSampleRate.toDouble() / outputSampleRate
        val estimatedFrames = max(1, ceil(inputFrames / sourceStep).toInt() + 1)
        val output = ByteArray(estimatedFrames * bytesPerFrame)
        var outputOffset = 0

        while (pcmReformatterSourceCursor < inputEnd && running) {
            val localPosition = pcmReformatterSourceCursor - inputStart
            if (localPosition < 0.0) {
                pcmReformatterSourceCursor += sourceStep
                continue
            }

            val leftFrame = floor(localPosition).toInt().coerceIn(0, inputFrames - 1)
            val rightFrame = min(leftFrame + 1, inputFrames - 1)
            val fraction = localPosition - floor(localPosition)
            for (channel in 0 until channelCount) {
                val left = readPcm16Frame(data, offset, leftFrame, channelCount, channel)
                val right = readPcm16Frame(data, offset, rightFrame, channelCount, channel)
                val sample = (left + (right - left) * fraction).roundToInt()
                    .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                    .toShort()
                writePcm16(output, outputOffset, sample)
                outputOffset += 2
            }

            pcmReformatterSourceCursor += sourceStep
        }

        pcmReformatterInputFramesConsumed += inputFrames.toLong()
        return output.copyOf(outputOffset)
    }

    private fun resetPcmReformatter(
        inputSampleRate: Int,
        channels: Int,
        outputSampleRate: Int
    ) {
        pcmReformatterInitialized = true
        pcmReformatterSourceCursor = 0.0
        pcmReformatterInputFramesConsumed = 0
        pcmReformatterInputSampleRate = inputSampleRate
        pcmReformatterChannels = channels
        pcmReformatterOutputSampleRate = outputSampleRate
    }

    private fun clearPcmReformatter() {
        pcmReformatterInitialized = false
        pcmReformatterSourceCursor = 0.0
        pcmReformatterInputFramesConsumed = 0
        pcmReformatterInputSampleRate = 0
        pcmReformatterChannels = 0
        pcmReformatterOutputSampleRate = 0
    }

    private fun writePcmToTrack(
        track: AudioTrack,
        data: ByteArray,
        offset: Int,
        size: Int
    ): Int {
        if (size <= 0) {
            return 0
        }

        if (!currentUseBlockingWrites && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val written = track.write(data, offset, size, AudioTrack.WRITE_NON_BLOCKING)
            logAudioTrackWrite(written, size)
            return written
        }

        var totalWritten = 0
        while (totalWritten < size && running) {
            val written = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                track.write(
                    data,
                    offset + totalWritten,
                    size - totalWritten,
                    AudioTrack.WRITE_BLOCKING
                )
            } else {
                track.write(data, offset + totalWritten, size - totalWritten)
            }
            if (written <= 0) {
                break
            }
            totalWritten += written
        }
        logAudioTrackWrite(totalWritten, size)
        return totalWritten
    }

    private fun logAudioTrackWrite(written: Int, requested: Int) {
        audioTrackWriteCount += 1
        if (audioTrackWriteCount <= 5 || audioTrackWriteCount % 1000L == 0L) {
            Log.i(
                LOG_TAG,
                "AudioTrack write #$audioTrackWriteCount written=$written requested=$requested playState=${audioTrack?.playState}"
            )
        }
    }

    private fun adaptPlaybackBuffer(
        track: AudioTrack,
        sampleRate: Int,
        queuedFrames: Long,
        underruns: Int
    ) {
        if (sampleRate <= 0) {
            return
        }
        val requestedLatencyMs = profile.playbackBufferMs.coerceIn(
            minLatencyMs(),
            MAX_LATENCY_MS
        )
        if (!profile.receiverAdaptiveBuffer) {
            resetAdaptiveBufferPressure(underruns)
            if (adaptivePlaybackBufferMs != requestedLatencyMs) {
                updateAdaptivePlaybackBuffer(sampleRate, requestedLatencyMs, remember = false)
            }
            return
        }

        val now = SystemClock.elapsedRealtime()
        val hasPlaybackSignal = hasAdaptivePlaybackSignal()
        if (!hasPlaybackSignal) {
            resetAdaptiveGrowthPressure(underruns)
            lastAdaptiveBufferRelaxAtMs = now
            return
        }

        val targetFrames = adaptiveTargetFrames(sampleRate).toLong()
        val networkFloorMs = adaptiveNetworkFloorBufferMs(requestedLatencyMs)
        val isPlaying = track.playState == AudioTrack.PLAYSTATE_PLAYING
        val isPlaybackStable = isPlaying &&
            playbackStartedAtMs > 0L &&
            now - playbackStartedAtMs >= ADAPTIVE_PLAYBACK_START_GRACE_MS
        val underrunDelta = if (isPlaybackStable) {
            (underruns - lastKnownUnderrunCount).coerceAtLeast(0)
        } else {
            lastKnownUnderrunCount = underruns
            0
        }
        var shouldIncrease = false
        var pressureIncrease = false
        if (underrunDelta > 0) {
            lastPlaybackPressureAtMs = now
            shouldIncrease = exceedsAdaptiveUnderrunBudget(now, underrunDelta)
            pressureIncrease = shouldIncrease
        }

        if (isPlaybackStable && isPlaybackQueueTooLow(sampleRate, queuedFrames, targetFrames)) {
            adaptiveLowQueueSamples += 1
            if (shouldGrowAdaptiveBufferForLowQueue(adaptiveLowQueueSamples)) {
                lastPlaybackPressureAtMs = now
                shouldIncrease = true
                pressureIncrease = true
            }
        } else {
            adaptiveLowQueueSamples = 0
        }

        val currentBufferMs = adaptivePlaybackBufferMs
        val networkFloorIncrease =
            networkFloorMs > currentBufferMs + ADAPTIVE_NETWORK_TARGET_HYSTERESIS_MS
        if (networkFloorIncrease) {
            shouldIncrease = true
        }

        if (shouldIncrease && now - lastAdaptiveBufferIncreaseAtMs >= ADAPTIVE_BUFFER_COOLDOWN_MS) {
            updateAdaptivePlaybackBuffer(
                sampleRate,
                adaptiveBufferIncreaseTargetMs(
                    currentBufferMs = currentBufferMs,
                    stepMs = adaptiveBufferStepMs(requestedLatencyMs),
                    networkFloorMs = networkFloorMs,
                    pressureIncrease = pressureIncrease,
                    networkFloorIncrease = networkFloorIncrease
                )
            )
            lastAdaptiveBufferIncreaseAtMs = now
            adaptiveLowQueueSamples = 0
        } else if (shouldRelaxAdaptiveBuffer(
                now = now,
                currentBufferMs = currentBufferMs,
                networkFloorMs = networkFloorMs,
                queuedFrames = queuedFrames,
                targetFrames = targetFrames,
                sampleRate = sampleRate
            )
        ) {
            updateAdaptivePlaybackBuffer(
                sampleRate,
                max(
                    networkFloorMs,
                    currentBufferMs - adaptiveBufferRelaxStepMs(requestedLatencyMs)
                )
            )
            lastAdaptiveBufferRelaxAtMs = now
        }

        lastKnownUnderrunCount = underruns
    }

    private fun shouldRelaxAdaptiveBuffer(
        now: Long,
        currentBufferMs: Int,
        networkFloorMs: Int,
        queuedFrames: Long,
        targetFrames: Long,
        sampleRate: Int
    ): Boolean {
        if (currentBufferMs <= networkFloorMs + ADAPTIVE_NETWORK_TARGET_HYSTERESIS_MS) {
            return false
        }
        if (queuedFrames < healthyPlaybackQueueFrames(sampleRate, targetFrames)) {
            return false
        }

        val queueAtOrAboveTarget = queuedFrames >= targetFrames
        val hasRoomToFastRelax =
            currentBufferMs - networkFloorMs >= ADAPTIVE_FAST_RELAX_MARGIN_MS
        val relaxDelayMs = if (queueAtOrAboveTarget && hasRoomToFastRelax) {
            adaptiveFastRelaxDelayMs()
        } else {
            adaptiveRelaxDelayMs()
        }
        val relaxGateMs = max(lastPlaybackPressureAtMs, lastAdaptiveBufferRelaxAtMs)
        return now - relaxGateMs >= relaxDelayMs
    }

    private fun resetAdaptiveBufferPressure(underruns: Int) {
        lastKnownUnderrunCount = underruns
        playbackStartedAtMs = 0L
        resetAdaptiveGrowthPressure(underruns, resetDelayTracker = true)
    }

    private fun resetAdaptiveGrowthPressure(
        underruns: Int,
        resetDelayTracker: Boolean = false
    ) {
        lastKnownUnderrunCount = underruns
        adaptiveUnderrunWindowStartAtMs = 0L
        adaptiveUnderrunsInWindow = 0
        adaptiveUnderrunBurstStartAtMs = 0L
        adaptiveUnderrunsInBurst = 0
        adaptiveLowQueueSamples = 0
        if (resetDelayTracker) {
            resetAdaptiveDelayTracker()
        }
    }

    private fun hasAdaptivePlaybackSignal(): Boolean {
        return !muted && signalLevel >= ADAPTIVE_AUDIBLE_SIGNAL_FLOOR
    }

    private fun resetAdaptiveDelayTracker() {
        adaptiveLastArrivalSequence = -1L
        adaptiveLastArrivalAtMs = 0L
        adaptiveLastPacketDurationMs = 0.0
        adaptiveRelativeDelayMs = 0.0
        adaptiveDelayWindowStartAtMs = 0L
        adaptiveDelayWindowPeakMs = 0.0
        adaptiveDelayHistoryMs.fill(0)
        adaptiveDelayHistoryIndex = 0
        adaptiveDelayHistoryCount = 0
        adaptiveNetworkTargetBufferMs = 0
    }

    private fun observeAdaptivePacketArrival(
        now: Long,
        sequence: Long,
        sampleRate: Int,
        packetFrames: Int
    ) {
        if (!profile.receiverAdaptiveBuffer || sampleRate <= 0 || packetFrames <= 0) {
            return
        }

        val packetDurationMs = packetFrames * 1000.0 / sampleRate
        if (
            adaptiveLastArrivalAtMs <= 0L ||
            adaptiveLastArrivalSequence < 0L ||
            now - adaptiveLastArrivalAtMs > SOURCE_IDLE_TIMEOUT_MS
        ) {
            seedAdaptiveDelayTracker(now, sequence, packetDurationMs)
            return
        }

        val sequenceDelta = packetSequenceDelta(sequence, adaptiveLastArrivalSequence)
        if (sequenceDelta <= 0L) {
            return
        }
        if (sequenceDelta > ADAPTIVE_SEQUENCE_RESET_GAP) {
            seedAdaptiveDelayTracker(now, sequence, packetDurationMs)
            return
        }

        val elapsedMs = (now - adaptiveLastArrivalAtMs).coerceAtLeast(0L).toDouble()
        val expectedMs = adaptiveLastPacketDurationMs * sequenceDelta.toDouble()
        adaptiveRelativeDelayMs = (adaptiveRelativeDelayMs + elapsedMs - expectedMs)
            .coerceIn(0.0, ADAPTIVE_DELAY_MAX_MS)
        if (adaptiveDelayWindowStartAtMs <= 0L) {
            adaptiveDelayWindowStartAtMs = adaptiveLastArrivalAtMs
        }
        adaptiveDelayWindowPeakMs = max(adaptiveDelayWindowPeakMs, adaptiveRelativeDelayMs)

        while (now - adaptiveDelayWindowStartAtMs >= ADAPTIVE_DELAY_SAMPLE_INTERVAL_MS) {
            recordAdaptiveDelaySample(ceil(adaptiveDelayWindowPeakMs).toInt())
            adaptiveDelayWindowStartAtMs += ADAPTIVE_DELAY_SAMPLE_INTERVAL_MS
            adaptiveDelayWindowPeakMs = adaptiveRelativeDelayMs
        }

        adaptiveLastArrivalSequence = sequence
        adaptiveLastArrivalAtMs = now
        adaptiveLastPacketDurationMs = packetDurationMs
    }

    private fun seedAdaptiveDelayTracker(
        now: Long,
        sequence: Long,
        packetDurationMs: Double
    ) {
        adaptiveLastArrivalSequence = sequence
        adaptiveLastArrivalAtMs = now
        adaptiveLastPacketDurationMs = packetDurationMs
        adaptiveRelativeDelayMs = 0.0
        adaptiveDelayWindowStartAtMs = now
        adaptiveDelayWindowPeakMs = 0.0
    }

    private fun recordAdaptiveDelaySample(delayMs: Int) {
        adaptiveDelayHistoryMs[adaptiveDelayHistoryIndex] = delayMs.coerceIn(
            0,
            ADAPTIVE_DELAY_MAX_MS.toInt()
        )
        adaptiveDelayHistoryIndex =
            (adaptiveDelayHistoryIndex + 1) % ADAPTIVE_DELAY_HISTORY_SAMPLES
        adaptiveDelayHistoryCount =
            min(ADAPTIVE_DELAY_HISTORY_SAMPLES, adaptiveDelayHistoryCount + 1)
    }

    private fun adaptiveNetworkFloorBufferMs(requestedLatencyMs: Int): Int {
        val estimatedDelayMs = adaptiveDelayQuantileMs()
        if (estimatedDelayMs <= 0 ||
            adaptiveDelayHistoryCount < ADAPTIVE_DELAY_MIN_HISTORY_SAMPLES
        ) {
            adaptiveNetworkTargetBufferMs = requestedLatencyMs
            return requestedLatencyMs
        }

        val packetGuardMs = max(
            profile.packetTimeMs.coerceIn(1, 12),
            ceil(adaptiveLastPacketDurationMs).toInt().coerceAtLeast(1)
        )
        if (estimatedDelayMs <= packetGuardMs) {
            adaptiveNetworkTargetBufferMs = requestedLatencyMs
            return requestedLatencyMs
        }
        val jitterBeyondGuardMs = estimatedDelayMs - packetGuardMs
        val jitterHeadroomMs = ceil(
            jitterBeyondGuardMs * ADAPTIVE_DELAY_HEADROOM_NUMERATOR.toDouble() /
                ADAPTIVE_DELAY_HEADROOM_DENOMINATOR
        ).toInt()
        adaptiveNetworkTargetBufferMs = (
            requestedLatencyMs + packetGuardMs + jitterHeadroomMs
            ).coerceIn(requestedLatencyMs, adaptiveMaxPlaybackBufferMs(requestedLatencyMs))
        return adaptiveNetworkTargetBufferMs
    }

    private fun adaptiveDelayQuantileMs(): Int {
        if (adaptiveDelayHistoryCount <= 0) {
            return 0
        }

        val samples = IntArray(adaptiveDelayHistoryCount)
        for (index in 0 until adaptiveDelayHistoryCount) {
            samples[index] = adaptiveDelayHistoryMs[index]
        }
        samples.sort()
        val quantileIndex = ceil(adaptiveDelayHistoryCount * ADAPTIVE_DELAY_QUANTILE)
            .toInt()
            .coerceIn(1, adaptiveDelayHistoryCount) - 1
        return samples[quantileIndex]
    }

    private fun packetSequenceDelta(sequence: Long, previousSequence: Long): Long {
        val rawDelta = if (sequence >= previousSequence) {
            sequence - previousSequence
        } else {
            sequence + SEQUENCE_MODULUS - previousSequence
        }
        return if (rawDelta > SEQUENCE_MODULUS / 2) 0L else rawDelta
    }

    private fun exceedsAdaptiveUnderrunBudget(now: Long, underrunDelta: Int): Boolean {
        if (
            adaptiveUnderrunWindowStartAtMs <= 0L ||
            now - adaptiveUnderrunWindowStartAtMs > ADAPTIVE_UNDERRUN_SLOW_WINDOW_MS
        ) {
            adaptiveUnderrunWindowStartAtMs = now
            adaptiveUnderrunsInWindow = 0
        }
        if (
            adaptiveUnderrunBurstStartAtMs <= 0L ||
            now - adaptiveUnderrunBurstStartAtMs > ADAPTIVE_UNDERRUN_BURST_WINDOW_MS
        ) {
            adaptiveUnderrunBurstStartAtMs = now
            adaptiveUnderrunsInBurst = 0
        }

        adaptiveUnderrunsInWindow += underrunDelta
        adaptiveUnderrunsInBurst += underrunDelta
        return adaptiveUnderrunsInBurst > ADAPTIVE_ACCEPTABLE_UNDERRUNS_PER_BURST ||
            adaptiveUnderrunsInWindow > ADAPTIVE_ACCEPTABLE_UNDERRUNS_PER_SLOW_WINDOW
    }

    private fun isPlaybackQueueTooLow(
        sampleRate: Int,
        queuedFrames: Long,
        targetFrames: Long
    ): Boolean {
        val lowQueueFrames = max(
            profile.packetFrames(sampleRate).toLong(),
            targetFrames / ADAPTIVE_LOW_QUEUE_DIVISOR
        )
        return queuedFrames < lowQueueFrames
    }

    private fun healthyPlaybackQueueFrames(sampleRate: Int, targetFrames: Long): Long {
        val requestedFrames = latencyFrames(
            sampleRate,
            profile.playbackBufferMs.coerceIn(minLatencyMs(), MAX_LATENCY_MS)
        ).toLong()
        return max(requestedFrames, targetFrames * 2L / 3L)
    }

    private fun adaptiveBufferStepMs(requestedLatencyMs: Int): Int {
        val packetStepMs = profile.packetTimeMs.coerceIn(1, 12) * 2
        val profileStepMs = when {
            requestedLatencyMs <= 28 -> ADAPTIVE_LOW_LATENCY_STEP_MS
            requestedLatencyMs <= LOW_LATENCY_PERFORMANCE_MAX_MS -> ADAPTIVE_BALANCED_STEP_MS
            else -> ADAPTIVE_STABLE_STEP_MS
        }
        return max(packetStepMs, profileStepMs).coerceAtMost(ADAPTIVE_STABLE_STEP_MS)
    }

    private fun adaptiveBufferRelaxStepMs(requestedLatencyMs: Int): Int {
        if (
            profile.mode == AudioMode.GAMING &&
            requestedLatencyMs <= LOW_LATENCY_PERFORMANCE_MAX_MS
        ) {
            return ADAPTIVE_GAMING_RELAX_STEP_MS
        }
        return adaptiveBufferStepMs(requestedLatencyMs)
    }

    private fun adaptiveRelaxDelayMs(): Long {
        return if (profile.mode == AudioMode.GAMING) {
            ADAPTIVE_GAMING_BUFFER_RELAX_MS
        } else {
            ADAPTIVE_BUFFER_RELAX_MS
        }
    }

    private fun adaptiveFastRelaxDelayMs(): Long {
        return if (profile.mode == AudioMode.GAMING) {
            ADAPTIVE_GAMING_BUFFER_FAST_RELAX_MS
        } else {
            ADAPTIVE_BUFFER_FAST_RELAX_MS
        }
    }

    private fun adaptiveMaxPlaybackBufferMs(
        requestedLatencyMs: Int = profile.playbackBufferMs.coerceIn(
            minLatencyMs(),
            MAX_LATENCY_MS
        )
    ): Int {
        val capMs = when (profile.mode) {
            AudioMode.GAMING -> ADAPTIVE_GAMING_CAP_MS
            AudioMode.BALANCED -> ADAPTIVE_BALANCED_CAP_MS
            AudioMode.MUSIC -> MAX_LATENCY_MS
            AudioMode.CUSTOM -> {
                if (profile.adaptiveBufferCapMs > 0) {
                    profile.adaptiveBufferCapMs
                } else {
                    MAX_LATENCY_MS
                }
            }
        }
        return capMs.coerceIn(requestedLatencyMs, MAX_LATENCY_MS)
    }

    private fun receiverOptionsFor(profile: AudioProfile): Int {
        val adaptiveFlag = if (profile.receiverAdaptiveBuffer) {
            RECEIVER_OPTION_ADAPTIVE_BUFFER
        } else {
            0
        }
        val modeFlag =
            (profile.mode.packetId shl RECEIVER_OPTION_MODE_SHIFT) and RECEIVER_OPTION_MODE_MASK
        val capFlag =
            (profile.adaptiveBufferCapMs.coerceIn(0, MAX_LATENCY_MS) shl
                RECEIVER_OPTION_CUSTOM_CAP_SHIFT) and RECEIVER_OPTION_CUSTOM_CAP_MASK
        val bitrateFlag =
            profile.bitrateKbps.coerceIn(0, RECEIVER_OPTION_BITRATE_MASK) shl
                RECEIVER_OPTION_BITRATE_SHIFT
        return adaptiveFlag or modeFlag or capFlag or bitrateFlag
    }

    private fun playbackQueueFillPercent(queuedFrames: Long, targetFrames: Int): Int {
        if (targetFrames <= 0) {
            return 0
        }
        return (queuedFrames * 100L / targetFrames)
            .coerceIn(0L, 200L)
            .toInt()
    }

    private fun refreshAdaptiveLinkMemoryKey() {
        adaptiveLinkMemoryKey = adaptiveLinkIdentityKey()
    }

    private fun initialAdaptivePlaybackBufferMs(): Int {
        val requestedLatencyMs = profile.playbackBufferMs.coerceIn(
            minLatencyMs(),
            MAX_LATENCY_MS
        )
        if (!profile.receiverAdaptiveBuffer) {
            return requestedLatencyMs
        }
        if (shouldStartAdaptiveBufferAtRequested(requestedLatencyMs)) {
            return requestedLatencyMs
        }

        val rememberedLatencyMs = rememberedAdaptivePlaybackBufferMs() ?: return requestedLatencyMs
        return rememberedLatencyMs.coerceIn(
            requestedLatencyMs,
            adaptiveMaxPlaybackBufferMs(requestedLatencyMs)
        )
    }

    private fun shouldStartAdaptiveBufferAtRequested(requestedLatencyMs: Int): Boolean {
        return profile.mode == AudioMode.GAMING ||
            requestedLatencyMs <= LOW_LATENCY_PERFORMANCE_MAX_MS
    }

    private fun rememberedAdaptivePlaybackBufferMs(): Int? {
        val key = adaptiveLinkMemoryKey ?: return null
        val storedAtMs = adaptiveLinkPreferences.getLong("${key}:updatedAtMs", 0L)
        if (
            storedAtMs <= 0L ||
            System.currentTimeMillis() - storedAtMs > ADAPTIVE_LINK_MEMORY_MAX_AGE_MS
        ) {
            return null
        }

        val storedBufferMs = adaptiveLinkPreferences.getInt("${key}:bufferMs", 0)
        return storedBufferMs.takeIf { it > 0 }
    }

    private fun rememberAdaptivePlaybackBufferMs(now: Long = SystemClock.elapsedRealtime()) {
        if (!profile.receiverAdaptiveBuffer) {
            return
        }
        val key = adaptiveLinkMemoryKey ?: return
        if (now - lastAdaptiveLinkMemoryWriteAtMs < ADAPTIVE_LINK_MEMORY_WRITE_COOLDOWN_MS) {
            return
        }

        val requestedLatencyMs = profile.playbackBufferMs.coerceIn(
            minLatencyMs(),
            MAX_LATENCY_MS
        )
        val learnedBufferMs = adaptivePlaybackBufferMs.coerceIn(
            requestedLatencyMs,
            adaptiveMaxPlaybackBufferMs(requestedLatencyMs)
        )
        adaptiveLinkPreferences.edit()
            .putInt("${key}:bufferMs", learnedBufferMs)
            .putLong("${key}:updatedAtMs", System.currentTimeMillis())
            .apply()
        lastAdaptiveLinkMemoryWriteAtMs = now
    }

    private fun updateAdaptivePlaybackBuffer(
        sampleRate: Int,
        nextBufferMs: Int,
        remember: Boolean = true
    ) {
        val requestedLatencyMs = profile.playbackBufferMs.coerceIn(
            minLatencyMs(),
            MAX_LATENCY_MS
        )
        val nextLatencyMs = nextBufferMs.coerceIn(
            requestedLatencyMs,
            adaptiveMaxPlaybackBufferMs(requestedLatencyMs)
        )
        var nextTargetFrames = min(currentBufferSizeFrames, latencyFrames(sampleRate, nextLatencyMs))
        val track = audioTrack
        if (track != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val adjustedFrames = track.setBufferSizeInFrames(nextTargetFrames)
            if (adjustedFrames > 0) {
                nextTargetFrames = min(currentBufferSizeFrames, adjustedFrames)
            }
        }
        currentTargetBufferFrames = max(1, nextTargetFrames)
        val previousPlaybackBufferMs = adaptivePlaybackBufferMs
        adaptivePlaybackBufferMs = (currentTargetBufferFrames * 1000L / sampleRate)
            .toInt()
            .coerceIn(minLatencyMs(), MAX_LATENCY_MS)
        if (remember && adaptivePlaybackBufferMs != previousPlaybackBufferMs) {
            rememberAdaptivePlaybackBufferMs()
        }
    }

    private fun adaptiveTargetFrames(sampleRate: Int): Int {
        return latencyFrames(sampleRate, adaptivePlaybackBufferMs)
    }

    private fun startPlaybackIfReady(track: AudioTrack, queuedFrames: Long) {
        if (track.playState == AudioTrack.PLAYSTATE_PLAYING) {
            return
        }
        if (queuedFrames < currentTargetBufferFrames) {
            return
        }

        try {
            track.play()
            playbackStartedAtMs = SystemClock.elapsedRealtime()
            lastKnownUnderrunCount = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                track.underrunCount
            } else {
                0
            }
            Log.i(LOG_TAG, "AudioTrack started queuedFrames=$queuedFrames target=$currentTargetBufferFrames")
        } catch (_: IllegalStateException) {
            Log.w(LOG_TAG, "AudioTrack play failed")
        }
    }

    private fun updateAudioLatencyEstimate(
        track: AudioTrack,
        sampleRate: Int,
        networkSampleMs: Double?
    ) {
        networkSampleMs ?: return
        val queuedFrames = max(0L, writtenFrames.get() - playbackFrames(track))
        val outputQueueMs = queuedFrames * 1000.0 / sampleRate
        networkLatencyMs = smoothLatency(networkLatencyMs, networkSampleMs)
        audioLatencyMs = smoothLatency(audioLatencyMs, networkSampleMs + outputQueueMs)
    }

    private fun estimateNetworkLatencyMs(
        packetReceivedAtReceiverMs: Long,
        senderSendTimeMs: Long,
        echoedReceiverTimeMs: Long,
        echoReceivedAtSenderTimeMs: Long
    ): Double? {
        if (
            packetReceivedAtReceiverMs <= 0 ||
            senderSendTimeMs <= 0 ||
            echoedReceiverTimeMs <= 0 ||
            echoReceivedAtSenderTimeMs <= 0
        ) {
            return null
        }

        val receiverRoundTripMs = packetReceivedAtReceiverMs - echoedReceiverTimeMs
        val senderDwellMs = senderSendTimeMs - echoReceivedAtSenderTimeMs
        if (receiverRoundTripMs < 0 || senderDwellMs < 0) {
            return null
        }

        return max(0.0, (receiverRoundTripMs - senderDwellMs) / 2.0)
    }

    private fun smoothLatency(previous: Double, sample: Double): Double {
        if (previous.isNaN()) {
            return sample
        }
        val previousWeight = if (sample < previous) 0.35 else 0.75
        return previous * previousWeight + sample * (1.0 - previousWeight)
    }

    private fun trimQueuedAudio(track: AudioTrack): Boolean {
        try {
            track.pause()
            track.flush()
            writtenFrames.set(playbackFrames(track))
            track.play()
            trimCount.incrementAndGet()
            audioLatencyMs = Double.NaN
            return true
        } catch (_: IllegalStateException) {
            return false
        }
    }

    private fun ensureAudioTrack(sampleRate: Int, channels: Int): AudioTrack? {
        if (
            sampleRate == currentSampleRate &&
            channels == currentChannels &&
            audioTrack != null
        ) {
            return audioTrack
        }

        releaseAudioTrack()

        val channelMask = when (channels) {
            1 -> AudioFormat.CHANNEL_OUT_MONO
            2 -> AudioFormat.CHANNEL_OUT_STEREO
            6 -> AudioFormat.CHANNEL_OUT_5POINT1
            else -> AudioFormat.CHANNEL_OUT_STEREO
        }
        val minBufferSize = AudioTrack.getMinBufferSize(
            sampleRate,
            channelMask,
            AudioFormat.ENCODING_PCM_16BIT
        )
        if (minBufferSize <= 0) {
            Log.w(LOG_TAG, "AudioTrack minBufferSize invalid=$minBufferSize sampleRate=$sampleRate channels=$channels")
            return null
        }

        val requestedLatencyMs = profile.playbackBufferMs.coerceIn(minLatencyMs(), MAX_LATENCY_MS)
        val adaptiveMaxBufferMs = adaptiveMaxPlaybackBufferMs(requestedLatencyMs)
        adaptivePlaybackBufferMs = adaptivePlaybackBufferMs.coerceIn(
            requestedLatencyMs,
            adaptiveMaxBufferMs
        )
        val requestedBufferFrames = latencyFrames(sampleRate, adaptivePlaybackBufferMs)
        val capacityBufferFrames = latencyFrames(
            sampleRate,
            if (profile.receiverAdaptiveBuffer) adaptiveMaxBufferMs else requestedLatencyMs
        )
        val startBufferFrames = if (profile.receiverAdaptiveBuffer) {
            max(
                requestedBufferFrames,
                latencyFrames(sampleRate, START_BUFFER_EXTRA_MS) + profile.packetFrames(
                    sampleRate = sampleRate,
                    multiplier = START_BUFFER_PACKETS
                )
            ).coerceAtMost(capacityBufferFrames)
        } else {
            requestedBufferFrames
        }
        val capacityBufferSize = max(
            minBufferSize,
            capacityBufferFrames * max(1, channels) * 2
        )
        val usage = if (requestedLatencyMs > LOW_LATENCY_PERFORMANCE_MAX_MS) {
            AudioAttributes.USAGE_MEDIA
        } else {
            AudioAttributes.USAGE_GAME
        }
        val attributes = AudioAttributes.Builder()
            .setUsage(usage)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()
        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(sampleRate)
            .setChannelMask(channelMask)
            .build()
        val builder = AudioTrack.Builder()
            .setAudioAttributes(attributes)
            .setAudioFormat(format)
            .setBufferSizeInBytes(capacityBufferSize)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setSessionId(AudioManager.AUDIO_SESSION_ID_GENERATE)
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            requestedLatencyMs <= LOW_LATENCY_PERFORMANCE_MAX_MS
        ) {
            builder.setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
        }

        val useBlockingWrites = shouldUseBlockingWrites(sampleRate, requestedLatencyMs)
        var actualBufferFrames = capacityBufferSize / (max(1, channels) * 2)
        var targetBufferFrames = startBufferFrames
        audioTrack = try {
            builder.build()
        } catch (error: IllegalArgumentException) {
            Log.w(LOG_TAG, "AudioTrack build failed", error)
            return null
        } catch (error: UnsupportedOperationException) {
            Log.w(LOG_TAG, "AudioTrack build unsupported", error)
            return null
        }.apply {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val adjustedFrames = setBufferSizeInFrames(startBufferFrames)
                if (adjustedFrames > 0) {
                    targetBufferFrames = adjustedFrames
                }
            }
            setVolume(if (muted) 0f else volume)
        }
        currentSampleRate = sampleRate
        currentChannels = channels
        currentBufferSizeFrames = actualBufferFrames
        currentTargetBufferFrames = min(actualBufferFrames, targetBufferFrames)
        currentUseBlockingWrites = useBlockingWrites
        adaptivePlaybackBufferMs = (currentTargetBufferFrames * 1000L / sampleRate)
            .toInt()
            .coerceIn(minLatencyMs(), MAX_LATENCY_MS)
        lastPlaybackHead = 0
        playbackHeadWraps = 0
        lastSequence = -1L
        lastKnownUnderrunCount = 0
        playbackStartedAtMs = 0L
        audioLatencyMs = Double.NaN
        networkLatencyMs = Double.NaN
        writtenFrames.set(0)
        audioTrackCreateCount += 1
        Log.i(
            LOG_TAG,
            "created AudioTrack #$audioTrackCreateCount sampleRate=$sampleRate channels=$channels minBuffer=$minBufferSize capacityBytes=$capacityBufferSize targetFrames=$currentTargetBufferFrames blocking=$currentUseBlockingWrites"
        )
        return audioTrack
    }

    private fun playbackFrames(track: AudioTrack): Long {
        val rawHead = track.playbackHeadPosition
        if (rawHead < lastPlaybackHead && lastPlaybackHead - rawHead > Int.MAX_VALUE / 2) {
            playbackHeadWraps += 1L
        }
        lastPlaybackHead = rawHead
        return (playbackHeadWraps shl 32) + rawHead.toLong()
    }

    private fun releaseAudioTrack() {
        audioTrack?.run {
            try {
                pause()
                flush()
                stop()
            } catch (_: IllegalStateException) {
            }
            release()
        }
        audioTrack = null
        releaseOpusDecoder()
        releaseAacDecoder()
        currentInputSampleRate = 0
        currentSampleRate = 0
        currentChannels = 0
        currentBufferSizeFrames = 0
        currentTargetBufferFrames = 0
        currentUseBlockingWrites = false
        lastSequence = -1L
        lastCodecId = CODEC_PCM
        lastKnownUnderrunCount = 0
        adaptiveUnderrunWindowStartAtMs = 0L
        adaptiveUnderrunsInWindow = 0
        adaptiveUnderrunBurstStartAtMs = 0L
        adaptiveUnderrunsInBurst = 0
        adaptiveLowQueueSamples = 0
        resetAdaptiveDelayTracker()
        lastAudioPacketReceivedAtMs = 0L
        clearPcmReformatter()
        audioLatencyMs = Double.NaN
        networkLatencyMs = Double.NaN
        signalLevel = 0.0
        writtenFrames.set(0)
    }

    private fun releaseOpusDecoder() {
        if (opusDecoderHandle != 0L) {
            opusNative.destroyDecoder(opusDecoderHandle)
        }
        opusDecoderHandle = 0
        opusChannels = 0
    }

    private fun releaseOpusEncoder() {
        if (opusEncoderHandle != 0L) {
            opusNative.destroyEncoder(opusEncoderHandle)
        }
        opusEncoderHandle = 0
        opusEncoderChannels = 0
        opusEncoderBitrateBps = 0
        opusEncoderLowDelay = false
    }

    private fun releaseAacDecoder() {
        aacDecoder?.run {
            try {
                stop()
            } catch (_: IllegalStateException) {
            }
            release()
        }
        aacDecoder = null
        aacSampleRate = 0
        aacChannels = 0
    }

    private fun releaseAacEncoder() {
        aacEncoder?.run {
            try {
                stop()
            } catch (_: IllegalStateException) {
            }
            release()
        }
        aacEncoder = null
        aacEncoderSampleRate = 0
        aacEncoderChannels = 0
        aacEncoderBitrateBps = 0
        aacEncoderSubmittedFrames = 0L
    }

    private fun latencyFrames(sampleRate: Int, latencyMs: Int): Int {
        return max(
            1,
            (sampleRate.toLong() * latencyMs.coerceIn(minLatencyMs(), MAX_LATENCY_MS) / 1000L).toInt()
        )
    }

    private fun shouldUseBlockingWrites(sampleRate: Int, requestedLatencyMs: Int): Boolean {
        val nativeRate = nativeOutputSampleRate
        return requestedLatencyMs > LOW_LATENCY_PERFORMANCE_MAX_MS ||
            (nativeRate > 0 && sampleRate != nativeRate)
    }

    private fun minLatencyMs(): Int {
        return if (transportMode == TransportMode.USB) USB_MIN_LATENCY_MS else MIN_LATENCY_MS
    }
}

private fun readNativeOutputSampleRate(): Int {
    val sampleRate = AudioTrack.getNativeOutputSampleRate(AudioManager.STREAM_MUSIC)
    return if (sampleRate > 0) sampleRate.coerceAtMost(MAX_OUTPUT_SAMPLE_RATE) else 0
}

private fun inputChannelMask(channels: Int): Int {
    return when (channels) {
        1 -> AudioFormat.CHANNEL_IN_MONO
        2 -> AudioFormat.CHANNEL_IN_STEREO
        else -> AudioFormat.CHANNEL_IN_MONO
    }
}

private fun latencyBytes(sampleRate: Int, channels: Int, latencyMs: Int): Int {
    val channelCount = max(1, channels)
    val bytesPerFrame = channelCount * 2
    val clampedLatencyMs = latencyMs.coerceIn(MIN_LATENCY_MS, MAX_LATENCY_MS)
    return max(1, (sampleRate.toLong() * bytesPerFrame * clampedLatencyMs / 1000L).toInt())
}

private fun isSubscribeMessage(data: ByteArray, length: Int): Boolean {
    val prefix = "ABR_SUBSCRIBE".toByteArray(Charsets.UTF_8)
    if (length < prefix.size) {
        return false
    }
    for (index in prefix.indices) {
        if (data[index] != prefix[index]) {
            return false
        }
    }
    return true
}

private fun parseDoubleMetric(message: String, key: String): Double? {
    val value = metricValue(message, key) ?: return null
    val parsed = value.toDoubleOrNull() ?: return null
    return if (parsed.isNaN() || parsed.isInfinite()) null else parsed
}

private fun parseLongMetric(message: String, key: String): Long? {
    return metricValue(message, key)?.toLongOrNull()
}

private fun parseStringMetric(message: String, key: String): String? {
    return metricValue(message, key)
}

private fun metricValue(message: String, key: String): String? {
    val token = "$key="
    val start = message.indexOf(token)
    if (start < 0) {
        return null
    }

    val valueStart = start + token.length
    val valueEnd = message.indexOf(' ', valueStart).let { index ->
        if (index < 0) message.length else index
    }
    return message.substring(valueStart, valueEnd).trim().takeIf { it.isNotEmpty() }
}

private fun readPcm16Frame(
    data: ByteArray,
    offset: Int,
    frame: Int,
    channels: Int,
    channel: Int
): Int {
    val index = offset + (frame * channels + channel) * 2
    val low = data[index].toInt() and 0xFF
    val high = data[index + 1].toInt()
    return (high shl 8) or low
}

private fun decodeG711MuLawPayload(data: ByteArray, offset: Int, payloadSize: Int): ByteArray {
    val output = ByteArray(payloadSize * 2)
    var out = 0
    for (index in offset until offset + payloadSize) {
        writePcm16(output, out, muLawToLinear(data[index].toInt() and 0xFF))
        out += 2
    }
    return output
}

private fun decodeG711ALawPayload(data: ByteArray, offset: Int, payloadSize: Int): ByteArray {
    val output = ByteArray(payloadSize * 2)
    var out = 0
    for (index in offset until offset + payloadSize) {
        writePcm16(output, out, aLawToLinear(data[index].toInt() and 0xFF))
        out += 2
    }
    return output
}

private fun muLawToLinear(encoded: Int): Short {
    val value = encoded.inv() and 0xFF
    val sign = value and 0x80
    val exponent = (value shr 4) and 0x07
    val mantissa = value and 0x0F
    var sample = ((mantissa shl 3) + 0x84) shl exponent
    sample -= 0x84
    return (if (sign != 0) -sample else sample).coerceIn(-32768, 32767).toShort()
}

private fun aLawToLinear(encoded: Int): Short {
    val value = encoded xor 0x55
    val sign = value and 0x80
    val exponent = (value and 0x70) shr 4
    val mantissa = value and 0x0F
    var sample = if (exponent == 0) {
        (mantissa shl 4) + 8
    } else {
        ((mantissa shl 4) + 0x108) shl (exponent - 1)
    }
    if (sign == 0) {
        sample = -sample
    }
    return sample.coerceIn(-32768, 32767).toShort()
}

private fun linearToMuLaw(sample: Short): Int {
    val bias = 0x84
    val clip = 32635
    var value = sample.toInt()
    val sign = (value shr 8) and 0x80
    if (sign != 0) {
        value = -value
    }
    value = min(value, clip) + bias

    var exponent = 7
    var mask = 0x4000
    while ((value and mask) == 0 && exponent > 0) {
        exponent -= 1
        mask = mask shr 1
    }
    val mantissa = (value shr (exponent + 3)) and 0x0F
    return (sign or (exponent shl 4) or mantissa).inv() and 0xFF
}

private fun linearToALaw(sample: Short): Int {
    var value = sample.toInt()
    var mask = 0xD5
    if (value < 0) {
        value = -value - 1
        mask = 0x55
    }
    value = min(value, 32635)

    val compressed = if (value >= 256) {
        var exponent = 7
        var exponentMask = 0x4000
        while ((value and exponentMask) == 0 && exponent > 0) {
            exponent -= 1
            exponentMask = exponentMask shr 1
        }
        val mantissa = (value shr (exponent + 3)) and 0x0F
        (exponent shl 4) or mantissa
    } else {
        value shr 4
    }

    return (compressed xor mask) and 0xFF
}

private fun writePcm16(output: ByteArray, offset: Int, sample: Short) {
    val value = sample.toInt()
    output[offset] = value.toByte()
    output[offset + 1] = (value shr 8).toByte()
}

private fun decodeImaAdpcmPayload(
    data: ByteArray,
    offset: Int,
    payloadSize: Int,
    channels: Int
): ByteArray? {
    val channelCount = max(1, channels)
    val stateBytes = channelCount * 4
    if (payloadSize <= stateBytes) {
        return null
    }

    val states = MutableList(channelCount) { channel ->
        val stateOffset = offset + channel * 4
        val predictor = (
            (data[stateOffset].toInt() and 0xFF) or
                (data[stateOffset + 1].toInt() shl 8)
            ).toShort().toInt()
        val stepIndex = (data[stateOffset + 2].toInt() and 0xFF).coerceIn(0, 88)
        ImaAdpcmChannelState(predictor, stepIndex)
    }
    val encodedOffset = offset + stateBytes
    val encodedSize = payloadSize - stateBytes
    val sampleCount = encodedSize * 2
    val output = ByteArray(sampleCount * 2)
    var out = 0
    var nextChannel = 0
    for (index in encodedOffset until encodedOffset + encodedSize) {
        val value = data[index].toInt() and 0xFF
        out = decodeImaNibble(value and 0x0F, states, nextChannel, output, out)
        nextChannel = (nextChannel + 1) % channelCount
        out = decodeImaNibble((value shr 4) and 0x0F, states, nextChannel, output, out)
        nextChannel = (nextChannel + 1) % channelCount
    }
    return output
}

private fun decodeImaNibble(
    nibble: Int,
    states: List<ImaAdpcmChannelState>,
    channel: Int,
    output: ByteArray,
    offset: Int
): Int {
    val sample = states[channel].decode(nibble)
    writePcm16(output, offset, sample)
    return offset + 2
}

private class ImaAdpcmChannelState {
    private var predictor: Int
    private var stepIndex: Int

    constructor(predictor: Int, stepIndex: Int) {
        this.predictor = predictor
        this.stepIndex = stepIndex
    }

    fun decode(nibble: Int): Short {
        val step = IMA_STEP_TABLE[stepIndex]
        var delta = step shr 3
        if ((nibble and 0x01) != 0) delta += step shr 2
        if ((nibble and 0x02) != 0) delta += step shr 1
        if ((nibble and 0x04) != 0) delta += step
        predictor += if ((nibble and 0x08) != 0) -delta else delta
        predictor = predictor.coerceIn(-32768, 32767)
        stepIndex = (stepIndex + IMA_INDEX_TABLE[nibble and 0x0F]).coerceIn(0, 88)
        return predictor.toShort()
    }
}

private data class ImaAdpcmEncodeState(
    var predictor: Int = 0,
    var stepIndex: Int = 0
)

private fun encodeImaNibble(sample: Short, state: ImaAdpcmEncodeState): Int {
    val step = IMA_STEP_TABLE[state.stepIndex]
    var diff = sample.toInt() - state.predictor
    var code = 0
    if (diff < 0) {
        code = 8
        diff = -diff
    }

    var delta = step shr 3
    if (diff >= step) {
        code = code or 4
        diff -= step
        delta += step
    }
    if (diff >= step shr 1) {
        code = code or 2
        diff -= step shr 1
        delta += step shr 1
    }
    if (diff >= step shr 2) {
        code = code or 1
        delta += step shr 2
    }

    state.predictor += if ((code and 8) != 0) -delta else delta
    state.predictor = state.predictor.coerceIn(-32768, 32767)
    state.stepIndex = (state.stepIndex + IMA_INDEX_TABLE[code and 0x0F]).coerceIn(0, 88)
    return code and 0x0F
}

private val IMA_INDEX_TABLE = intArrayOf(
    -1, -1, -1, -1, 2, 4, 6, 8,
    -1, -1, -1, -1, 2, 4, 6, 8
)

private val IMA_STEP_TABLE = intArrayOf(
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17,
    19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
    50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
    130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
    337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
    876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
    2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
    5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
    15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
)

private data class AudioProfile(
    val mode: AudioMode = AudioMode.BALANCED,
    val codec: Int = CODEC_PCM,
    val outputBackend: OutputAudioBackend = OutputAudioBackend.AUTO,
    val sampleRate: Int = 48000,
    val bitrateKbps: Int = 192,
    val channels: Int = 2,
    val latencyMs: Int = 35,
    val captureBufferMs: Int = 35,
    val playbackBufferMs: Int = 35,
    val packetTimeMs: Int = 3,
    val receiverAdaptiveBuffer: Boolean = true,
    val adaptiveBufferCapMs: Int = 0
) {
    fun packetFrames(sampleRate: Int = this.sampleRate, multiplier: Int = 1): Int {
        val clampedPacketTimeMs = packetTimeMs.coerceIn(1, 12)
        val frames = sampleRate.toLong() * clampedPacketTimeMs * multiplier / 1000L
        return max(1, frames.toInt())
    }

    fun toMap(): Map<String, Any> = mapOf(
        "mode" to mode.name.lowercase(Locale.US),
        "codec" to codecName(codec),
        "outputBackend" to outputBackendName(outputBackend),
        "sampleRate" to sampleRate,
        "bitrateKbps" to bitrateKbps,
        "latencyMs" to latencyMs,
        "captureBufferMs" to captureBufferMs,
        "playbackBufferMs" to playbackBufferMs,
        "packetTimeMs" to packetTimeMs,
        "channels" to channels,
        "receiverAdaptiveBuffer" to receiverAdaptiveBuffer,
        "adaptiveBufferCapMs" to adaptiveBufferCapMs
    )

    companion object {
        fun from(arguments: Any?): AudioProfile {
            val map = arguments as? Map<*, *> ?: return AudioProfile()
            val latencyMs = (map["latencyMs"] as? Number)?.toInt() ?: 35
            return AudioProfile(
                mode = AudioMode.fromName(map["mode"]?.toString()),
                codec = codecFromName(map["codec"]?.toString()),
                outputBackend = OutputAudioBackend.fromName(map["outputBackend"]?.toString()),
                sampleRate = (map["sampleRate"] as? Number)?.toInt() ?: 48000,
                bitrateKbps = (map["bitrateKbps"] as? Number)?.toInt() ?: 192,
                channels = ((map["channels"] as? Number)?.toInt() ?: 2).coerceIn(1, 2),
                latencyMs = latencyMs,
                captureBufferMs = (map["captureBufferMs"] as? Number)?.toInt() ?: latencyMs,
                playbackBufferMs = (map["playbackBufferMs"] as? Number)?.toInt() ?: latencyMs,
                packetTimeMs = (map["packetTimeMs"] as? Number)?.toInt() ?: 3,
                receiverAdaptiveBuffer = (map["receiverAdaptiveBuffer"] as? Boolean) ?: true,
                adaptiveBufferCapMs = (map["adaptiveBufferCapMs"] as? Number)?.toInt() ?: 0
            )
        }

        private fun codecFromName(value: String?): Int {
            return when (value?.lowercase(Locale.US)?.replace(Regex("[-_\\s]"), "")) {
                "opus" -> CODEC_OPUS
                "aac",
                "aaclc",
                "acc" -> CODEC_AAC
                "g711mulaw" -> CODEC_G711_MU_LAW
                "g711alaw" -> CODEC_G711_A_LAW
                "imaadpcm" -> CODEC_IMA_ADPCM
                else -> CODEC_PCM
            }
        }

        private fun codecName(value: Int): String {
            return when (value) {
                CODEC_OPUS -> "opus"
                CODEC_AAC -> "aac"
                CODEC_G711_MU_LAW -> "g711MuLaw"
                CODEC_G711_A_LAW -> "g711ALaw"
                CODEC_IMA_ADPCM -> "imaAdpcm"
                else -> "pcm"
            }
        }

        private fun outputBackendName(value: OutputAudioBackend): String {
            return when (value) {
                OutputAudioBackend.AUDIO_TRACK -> "audioTrack"
                OutputAudioBackend.OBOE -> "oboe"
                OutputAudioBackend.AUTO -> "auto"
            }
        }
    }
}
