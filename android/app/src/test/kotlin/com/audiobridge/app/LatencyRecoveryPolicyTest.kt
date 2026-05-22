package com.audiobridge.app

import org.junit.Assert.assertEquals
import org.junit.Test

class LatencyRecoveryPolicyTest {
    @Test
    fun acceptsWhenLatencyStaysWithinHardLimit() {
        assertEquals(
            LatencyRecoveryDecision.ACCEPT,
            latencyRecoveryDecision(
                queuedFrames = framesForMs(30),
                targetFrames = framesForMs(30),
                packetFrames = framesForMs(1),
                hardLimitFrames = framesForMs(90),
                sampleRate = sampleRate,
                networkSampleMs = 40.0
            )
        )
    }

    @Test
    fun trimsAndAcceptsWhenQueuedAudioCausesExcessLatency() {
        assertEquals(
            LatencyRecoveryDecision.TRIM_AND_ACCEPT,
            latencyRecoveryDecision(
                queuedFrames = framesForMs(62),
                targetFrames = framesForMs(30),
                packetFrames = framesForMs(1),
                hardLimitFrames = framesForMs(90),
                sampleRate = sampleRate,
                networkSampleMs = 40.0
            )
        )
    }

    @Test
    fun dropsWhenIncomingPacketIsAlreadyTooLate() {
        assertEquals(
            LatencyRecoveryDecision.DROP,
            latencyRecoveryDecision(
                queuedFrames = framesForMs(30),
                targetFrames = framesForMs(30),
                packetFrames = framesForMs(1),
                hardLimitFrames = framesForMs(90),
                sampleRate = sampleRate,
                networkSampleMs = 100.0
            )
        )
    }

    @Test
    fun trimsAndDropsWhenQueueAndPacketAreBothStale() {
        assertEquals(
            LatencyRecoveryDecision.TRIM_AND_DROP,
            latencyRecoveryDecision(
                queuedFrames = framesForMs(62),
                targetFrames = framesForMs(30),
                packetFrames = framesForMs(1),
                hardLimitFrames = framesForMs(90),
                sampleRate = sampleRate,
                networkSampleMs = 100.0
            )
        )
    }

    @Test
    fun trimsWithoutNetworkSampleWhenQueueExceedsHardLimit() {
        assertEquals(
            LatencyRecoveryDecision.TRIM_AND_ACCEPT,
            latencyRecoveryDecision(
                queuedFrames = framesForMs(95),
                targetFrames = framesForMs(30),
                packetFrames = framesForMs(1),
                hardLimitFrames = framesForMs(90),
                sampleRate = sampleRate,
                networkSampleMs = null
            )
        )
    }

    private fun framesForMs(milliseconds: Int): Long {
        return sampleRate.toLong() * milliseconds / 1000L
    }

    private companion object {
        const val sampleRate = 48000
    }
}
