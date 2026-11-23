package com.audiobridge.app

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build

internal enum class AudioFocusState {
    FULL,
    DUCKED,
    MUTED
}

internal object AudioFocusPolicy {
    const val DUCK_GAIN_MULTIPLIER = 0.25f

    fun stateForFocusChange(focusChange: Int): AudioFocusState {
        return when (focusChange) {
            AudioManager.AUDIOFOCUS_GAIN,
            AudioManager.AUDIOFOCUS_GAIN_TRANSIENT,
            AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK -> AudioFocusState.FULL
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> AudioFocusState.DUCKED
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
            AudioManager.AUDIOFOCUS_LOSS -> AudioFocusState.MUTED
            else -> AudioFocusState.FULL
        }
    }

    fun gainMultiplierFor(state: AudioFocusState): Float {
        return when (state) {
            AudioFocusState.FULL -> 1.0f
            AudioFocusState.DUCKED -> DUCK_GAIN_MULTIPLIER
            AudioFocusState.MUTED -> 0.0f
        }
    }
}

internal class AudioFocusController(
    context: Context,
    private val onStateChanged: (AudioFocusState) -> Unit
) {
    private val audioManager =
        context.applicationContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
    private var focusRequest: AudioFocusRequest? = null
    private var hasFocusRequest = false

    @Volatile
    var state: AudioFocusState = AudioFocusState.FULL
        private set

    val gainMultiplier: Float
        get() = AudioFocusPolicy.gainMultiplierFor(state)

    val isMutedByFocus: Boolean
        get() = state == AudioFocusState.MUTED

    private val focusChangeListener = AudioManager.OnAudioFocusChangeListener { change ->
        val nextState = AudioFocusPolicy.stateForFocusChange(change)
        if (state != nextState) {
            state = nextState
            onStateChanged(nextState)
        }
    }

    fun requestFocus(): Boolean {
        val manager = audioManager ?: return true
        if (hasFocusRequest) {
            return true
        }
        val result = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val attributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                .build()
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(attributes)
                .setAcceptsDelayedFocusGain(false)
                .setWillPauseWhenDucked(false)
                .setOnAudioFocusChangeListener(focusChangeListener)
                .build()
            focusRequest = request
            manager.requestAudioFocus(request)
        } else {
            @Suppress("DEPRECATION")
            manager.requestAudioFocus(
                focusChangeListener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN
            )
        }
        hasFocusRequest = true
        state = if (result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
            AudioFocusState.FULL
        } else {
            AudioFocusState.MUTED
        }
        onStateChanged(state)
        return result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    fun abandonFocus() {
        val manager = audioManager
        if (manager != null && hasFocusRequest) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                focusRequest?.let { manager.abandonAudioFocusRequest(it) }
                focusRequest = null
            } else {
                @Suppress("DEPRECATION")
                manager.abandonAudioFocus(focusChangeListener)
            }
        }
        hasFocusRequest = false
        if (state != AudioFocusState.FULL) {
            state = AudioFocusState.FULL
            onStateChanged(state)
        }
    }
}
