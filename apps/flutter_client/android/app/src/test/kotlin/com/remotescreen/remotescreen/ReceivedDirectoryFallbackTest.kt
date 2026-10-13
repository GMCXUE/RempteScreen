package com.remotescreen.remotescreen

import org.junit.Assert.*
import org.junit.Test

class ReceivedDirectoryFallbackTest {
    @Test fun permissionDeniedStillOpensDownloads() {
        var downloadsOpened = false
        assertTrue(ReceivedDirectoryFallback.open(
            { throw SecurityException("Cannot grant directory URI") },
            { downloadsOpened = true },
        ))
        assertTrue(downloadsOpened)
    }

    @Test fun unsupportedFolderHandlerStillOpensDownloads() {
        var downloadsOpened = false
        assertTrue(ReceivedDirectoryFallback.open(
            { throw RuntimeException("No folder activity") },
            { downloadsOpened = true },
        ))
        assertTrue(downloadsOpened)
    }

    @Test fun workingFolderDoesNotLaunchAnotherActivity() {
        assertTrue(ReceivedDirectoryFallback.open({}, { fail("Unexpected downloads launch") }))
    }

    @Test fun missingOrDisabledHandlersReturnFailureForManualLocationFallback() {
        assertFalse(ReceivedDirectoryFallback.open(
            { throw SecurityException("Disabled folder handler") },
            { throw RuntimeException("No downloads activity") },
        ))
    }
}
