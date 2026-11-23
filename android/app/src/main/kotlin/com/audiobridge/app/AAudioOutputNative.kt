package com.audiobridge.app

class AAudioOutputNative {
    external fun isAvailable(): Boolean

    external fun createStream(
        sampleRate: Int,
        channels: Int,
        capacityFrames: Int,
        targetFrames: Int,
        lowLatency: Boolean
    ): Long

    external fun startStream(handle: Long): Boolean

    external fun writePcm(
        handle: Long,
        data: ByteArray,
        offset: Int,
        sizeBytes: Int,
        blocking: Boolean
    ): Int

    external fun setBufferSizeInFrames(handle: Long, frames: Int): Int

    external fun getBufferCapacityInFrames(handle: Long): Int

    external fun getFramesRead(handle: Long): Long

    external fun getXRunCount(handle: Long): Int

    external fun isPlaying(handle: Long): Boolean

    external fun setVolume(handle: Long, volume: Float)

    external fun flush(handle: Long): Boolean

    external fun closeStream(handle: Long)

    companion object {
        init {
            System.loadLibrary("audiobridge_opus")
        }
    }
}
