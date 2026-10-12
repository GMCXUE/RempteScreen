package com.remotescreen.remotescreen

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.security.MessageDigest

class UpdatePackageStreamTest {
    private fun sha(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    @Test fun stagesExactValidatedBytesAcrossBufferBoundaries() {
        val apk = ByteArray(200003) { (it % 251).toByte() }
        val staged = ByteArrayOutputStream()
        UpdatePackageStream.copyVerified(ByteArrayInputStream(apk), staged, apk.size.toLong(), sha(apk))
        assertArrayEquals(apk, staged.toByteArray())
    }
    @Test fun refusesTruncatedExpandedAndModifiedApkBeforeCommit() {
        val apk = byteArrayOf(1,2,3,4)
        for (bytes in listOf(apk.copyOf(3), apk + byteArrayOf(5), byteArrayOf(1,2,3,5))) {
            try {
                UpdatePackageStream.copyVerified(ByteArrayInputStream(bytes), ByteArrayOutputStream(), 4, sha(apk))
                fail("Changed package must not be committed")
            } catch (_: IllegalArgumentException) {}
        }
    }
}
