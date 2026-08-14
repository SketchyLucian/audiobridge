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
    fun acceptsLatePacketWhenQueueCannotReduceNetworkLatency() {
        assertEquals(
            LatencyRecoveryDecision.ACCEPT,
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
    fun dropsLatePacketWhenQueueIsAboveTargetButCannotTrim() {
        assertEquals(
            LatencyRecoveryDecision.DROP,
            latencyRecoveryDecision(
                queuedFrames = framesForMs(31),
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

    @Test
    fun sustainedLowQueueTriggersAdaptiveBufferGrowth() {
        assertEquals(false, shouldGrowAdaptiveBufferForLowQueue(2))
        assertEquals(true, shouldGrowAdaptiveBufferForLowQueue(3))
    }

    @Test
    fun networkFloorIncreaseJumpsToMeasuredFloor() {
        assertEquals(
            96,
            adaptiveBufferIncreaseTargetMs(
                currentBufferMs = 30,
                stepMs = 8,
                networkFloorMs = 96,
                pressureIncrease = false,
                networkFloorIncrease = true
            )
        )
    }

    @Test
    fun nonPressureIncreaseKeepsNormalStep() {
        assertEquals(
            38,
            adaptiveBufferIncreaseTargetMs(
                currentBufferMs = 30,
                stepMs = 8,
                networkFloorMs = 96,
                pressureIncrease = false,
                networkFloorIncrease = false
            )
        )
    }

    @Test
    fun catchUpLeavesHealthyPlaybackQueueUnchanged() {
        assertEquals(
            framesForMs(3).toInt(),
            playbackCatchUpFrameCount(
                packetFrames = framesForMs(3).toInt(),
                queuedFrames = framesForMs(34),
                targetFrames = framesForMs(30),
                sampleRate = sampleRate
            )
        )
    }

    @Test
    fun catchUpGraduallyShortensPacketsWhenQueueStartsDrifting() {
        assertEquals(
            framesForMs(3).toInt() - 1,
            playbackCatchUpFrameCount(
                packetFrames = framesForMs(3).toInt(),
                queuedFrames = framesForMs(34) + 1,
                targetFrames = framesForMs(30),
                sampleRate = sampleRate
            )
        )
    }

    @Test
    fun catchUpCapsCorrectionToAvoidAudibleSpeedJump() {
        val packetFrames = framesForMs(3).toInt()

        assertEquals(
            packetFrames - 3,
            playbackCatchUpFrameCount(
                packetFrames = packetFrames,
                queuedFrames = framesForMs(130),
                targetFrames = framesForMs(30),
                sampleRate = sampleRate
            )
        )
    }

    @Test
    fun steadyClockSkewDoesNotAccumulateAsNetworkJitter() {
        var delaySampleMs = 0.0

        repeat(10_000) {
            delaySampleMs = packetArrivalDelaySampleMs(
                elapsedMs = 3.003,
                expectedMs = 3.0
            )
        }

        assertEquals(0.003, delaySampleMs, 0.000_001)
    }

    @Test
    fun latePacketProducesBoundedJitterSample() {
        assertEquals(
            27.0,
            packetArrivalDelaySampleMs(elapsedMs = 30.0, expectedMs = 3.0),
            0.0
        )
    }

    @Test
    fun earlyPacketDoesNotCreatePlaybackPressure() {
        assertEquals(
            0.0,
            packetArrivalDelaySampleMs(elapsedMs = 1.5, expectedMs = 3.0),
            0.0
        )
    }

    private fun framesForMs(milliseconds: Int): Long {
        return sampleRate.toLong() * milliseconds / 1000L
    }

    private companion object {
        const val sampleRate = 48000
    }
}
