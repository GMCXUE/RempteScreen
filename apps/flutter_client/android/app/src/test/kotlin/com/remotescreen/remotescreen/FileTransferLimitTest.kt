package com.remotescreen.remotescreen
import org.junit.Assert.*
import org.junit.Test
import java.io.InputStream
import java.io.OutputStream

class FileTransferLimitTest {
    private fun source(size: Long) = object : InputStream() {
        var remaining = size
        override fun read(): Int { if (remaining <= 0) return -1; remaining--; return 0 }
        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (remaining <= 0) return -1
            val count = minOf(remaining, len.toLong()).toInt(); remaining -= count; return count
        }
    }
    @Test fun exactLimitAndEmptyFilesAreAllowed() {
        val discard = object : OutputStream() { override fun write(b: Int) {} ; override fun write(b: ByteArray, off: Int, len: Int) {} }
        FileTransferLimit.check(-1) // unknown provider size still uses bounded copy
        assertEquals(0L, FileTransferLimit.copy(source(0), discard))
        assertEquals(FileTransferLimit.MAX_BYTES, FileTransferLimit.copy(source(FileTransferLimit.MAX_BYTES), discard))
    }
    @Test fun lyingProviderCannotCopyMoreThanLimit() {
        var written = 0L
        val sink = object : OutputStream() { override fun write(b: Int) {written++}; override fun write(b: ByteArray, off: Int, len: Int) {written += len} }
        try { FileTransferLimit.copy(source(FileTransferLimit.MAX_BYTES + 1), sink); fail("oversized file accepted") }
        catch (e: IllegalArgumentException) { assertEquals(FileTransferLimit.MESSAGE, e.message) }
        assertEquals(FileTransferLimit.MAX_BYTES, written)
    }
    @Test fun declaredOversizeRejectedBeforeCopy() {
        try {FileTransferLimit.check(FileTransferLimit.MAX_BYTES+1); fail("oversized metadata accepted")}
        catch (e: IllegalArgumentException) {assertEquals(FileTransferLimit.MESSAGE, e.message)}
    }
}
