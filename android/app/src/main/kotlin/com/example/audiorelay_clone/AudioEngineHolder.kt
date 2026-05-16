package com.example.audiorelay_clone

import android.content.Context

object AudioEngineHolder {
    @Volatile
    private var receiverEngine: AudioReceiverEngine? = null

    fun receiverEngine(context: Context): AudioReceiverEngine {
        return receiverEngine ?: synchronized(this) {
            receiverEngine ?: AudioReceiverEngine(context.applicationContext).also {
                receiverEngine = it
            }
        }
    }
}
