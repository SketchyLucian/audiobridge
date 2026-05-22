package com.audiobridge.app

class OpusNative {
    external fun createDecoder(channels: Int): Long

    external fun decode(handle: Long, input: ByteArray, offset: Int, size: Int): ByteArray?

    external fun destroyDecoder(handle: Long)

    external fun createEncoder(channels: Int, bitrateBps: Int, lowDelay: Boolean): Long

    external fun encode(handle: Long, input: ShortArray, frameSamples: Int): ByteArray?

    external fun destroyEncoder(handle: Long)

    companion object {
        init {
            System.loadLibrary("audiobridge_opus")
        }
    }
}
