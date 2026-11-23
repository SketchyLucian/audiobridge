package com.audiobridge.app

import android.media.AudioManager
import org.junit.Assert.assertEquals
import org.junit.Test

class AudioFocusPolicyTest {
    @Test
    fun mapsFocusEventsToExpectedGainStates() {
        assertEquals(
            AudioFocusState.FULL,
            AudioFocusPolicy.stateForFocusChange(AudioManager.AUDIOFOCUS_GAIN)
        )
        assertEquals(
            AudioFocusState.DUCKED,
            AudioFocusPolicy.stateForFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK)
        )
        assertEquals(
            AudioFocusState.MUTED,
            AudioFocusPolicy.stateForFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)
        )
        assertEquals(
            AudioFocusState.MUTED,
            AudioFocusPolicy.stateForFocusChange(AudioManager.AUDIOFOCUS_LOSS)
        )
    }

    @Test
    fun computesExpectedGainMultipliers() {
        assertEquals(1.0f, AudioFocusPolicy.gainMultiplierFor(AudioFocusState.FULL), 0.0001f)
        assertEquals(0.25f, AudioFocusPolicy.gainMultiplierFor(AudioFocusState.DUCKED), 0.0001f)
        assertEquals(0.0f, AudioFocusPolicy.gainMultiplierFor(AudioFocusState.MUTED), 0.0001f)
    }
}
