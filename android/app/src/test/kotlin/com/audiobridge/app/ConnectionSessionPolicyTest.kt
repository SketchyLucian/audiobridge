package com.audiobridge.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ConnectionSessionPolicyTest {
    @Test
    fun matchingNonZeroSessionIsAccepted() {
        assertTrue(acceptsSessionPacket(42L, 42L))
    }

    @Test
    fun staleOrMissingSessionIsRejected() {
        assertFalse(acceptsSessionPacket(42L, 41L))
        assertFalse(acceptsSessionPacket(0L, 0L))
    }

    @Test
    fun legacyPacketsAreRejectedAfterSessionProtocolActivates() {
        assertTrue(acceptsLegacyPacket(sessionProtocolActive = false))
        assertFalse(acceptsLegacyPacket(sessionProtocolActive = true))
    }

    @Test
    fun onlyWifiStreamsRequireWifiLock() {
        assertTrue(requiresWifiLock(TransportMode.WIFI))
        assertFalse(requiresWifiLock(TransportMode.USB_TETHERING))
        assertFalse(requiresWifiLock(TransportMode.USB))
    }

    @Test
    fun relayTransportNamesMapToNativeTransportPolicy() {
        assertEquals(TransportMode.WIFI, transportModeFromName("wifi"))
        assertEquals(
            TransportMode.USB_TETHERING,
            transportModeFromName("usbTethering")
        )
        assertEquals(TransportMode.USB, transportModeFromName("usb"))
    }
}
