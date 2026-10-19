package org.mewx.wenku8_flutter

import org.junit.Assert.assertEquals
import org.junit.Test

class NetworkStatePolicyTest {
    @Test fun validationIsIndependentOfTransportOrChipVendor() {
        assertEquals("online", NetworkStatePolicy.classify(true, true))
        assertEquals("offline", NetworkStatePolicy.classify(false, false))
    }

    @Test fun pendingCapabilitiesWaitForTheFlutterHandoverGrace() {
        assertEquals("checking", NetworkStatePolicy.classify(null, false))
        assertEquals("checking", NetworkStatePolicy.classify(true, false))
    }

    @Test fun blockedDefaultNetworkDoesNotAppearOnline() {
        assertEquals("offline", NetworkStatePolicy.classify(true, true, blocked = true))
    }
}
