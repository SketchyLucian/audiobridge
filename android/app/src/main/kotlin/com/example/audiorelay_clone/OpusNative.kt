package com.example.audiorelay_clone

class OpusNative {
    external fun createDecoder(channels: Int): Long

    external fun decode(handle: Long, input: ByteArray, offset: Int, size: Int): ByteArray?

    external fun destroyDecoder(handle: Long)

    companion object {
        init {
            System.loadLibrary("audiobridge_opus")
        }
    }
}
