package com.audiobridge.app

import android.media.AudioTrack
import android.os.Build

internal interface PlaybackOutputSink {
    val backendName: String
    val bufferCapacityFrames: Int
    val isPlaying: Boolean
    val playStateDebug: Int

    fun play(): Boolean
    fun write(data: ByteArray, offset: Int, size: Int, blocking: Boolean): Int
    fun setBufferSizeInFrames(frames: Int): Int
    fun playbackFrames(): Long
    fun underrunCount(): Int
    fun setVolume(gain: Float)
    fun trimFlush(): Boolean
    fun release()
}

internal class AudioTrackOutputSink(
    private val track: AudioTrack,
    override val bufferCapacityFrames: Int
) : PlaybackOutputSink {
    private var lastPlaybackHead = 0
    private var playbackHeadWraps = 0L

    override val backendName: String = "audioTrack"

    override val isPlaying: Boolean
        get() = track.playState == AudioTrack.PLAYSTATE_PLAYING

    override val playStateDebug: Int
        get() = track.playState

    override fun play(): Boolean {
        return try {
            track.play()
            true
        } catch (_: IllegalStateException) {
            false
        }
    }

    override fun write(data: ByteArray, offset: Int, size: Int, blocking: Boolean): Int {
        if (size <= 0) {
            return 0
        }
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val mode = if (blocking) {
                AudioTrack.WRITE_BLOCKING
            } else {
                AudioTrack.WRITE_NON_BLOCKING
            }
            track.write(data, offset, size, mode)
        } else {
            track.write(data, offset, size)
        }
    }

    override fun setBufferSizeInFrames(frames: Int): Int {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            track.setBufferSizeInFrames(frames)
        } else {
            0
        }
    }

    override fun playbackFrames(): Long {
        val rawHead = track.playbackHeadPosition
        if (rawHead < lastPlaybackHead && lastPlaybackHead - rawHead > Int.MAX_VALUE / 2) {
            playbackHeadWraps += 1L
        }
        lastPlaybackHead = rawHead
        return (playbackHeadWraps shl 32) + rawHead.toLong()
    }

    override fun underrunCount(): Int {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            track.underrunCount
        } else {
            0
        }
    }

    override fun setVolume(gain: Float) {
        try {
            track.setVolume(gain.coerceIn(0f, 1f))
        } catch (_: IllegalStateException) {
        }
    }

    override fun trimFlush(): Boolean {
        return try {
            track.pause()
            track.flush()
            track.play()
            true
        } catch (_: IllegalStateException) {
            false
        }
    }

    override fun release() {
        try {
            track.pause()
            track.flush()
            track.stop()
        } catch (_: IllegalStateException) {
        }
        track.release()
    }
}

internal class AAudioOutputSink(
    private val native: AAudioOutputNative,
    private var handle: Long,
    override val bufferCapacityFrames: Int
) : PlaybackOutputSink {
    override val backendName: String = "oboe"

    override val isPlaying: Boolean
        get() = handle != 0L && native.isPlaying(handle)

    override val playStateDebug: Int
        get() = if (isPlaying) 3 else 1

    override fun play(): Boolean {
        return handle != 0L && native.startStream(handle)
    }

    override fun write(data: ByteArray, offset: Int, size: Int, blocking: Boolean): Int {
        if (handle == 0L || size <= 0) {
            return 0
        }
        return native.writePcm(handle, data, offset, size, blocking)
    }

    override fun setBufferSizeInFrames(frames: Int): Int {
        if (handle == 0L || frames <= 0) {
            return 0
        }
        return native.setBufferSizeInFrames(handle, frames)
    }

    override fun playbackFrames(): Long {
        if (handle == 0L) {
            return 0L
        }
        return native.getFramesRead(handle).coerceAtLeast(0L)
    }

    override fun underrunCount(): Int {
        if (handle == 0L) {
            return 0
        }
        return native.getXRunCount(handle).coerceAtLeast(0)
    }

    override fun setVolume(gain: Float) {
        if (handle != 0L) {
            native.setVolume(handle, gain.coerceIn(0f, 1f))
        }
    }

    override fun trimFlush(): Boolean {
        return handle != 0L && native.flush(handle)
    }

    override fun release() {
        val current = handle
        handle = 0L
        if (current != 0L) {
            native.closeStream(current)
        }
    }
}
