package com.remotescreen.remotescreen

import java.io.InputStream
import java.io.OutputStream

internal object FileTransferLimit {
    const val MAX_BYTES = 50L * 1024 * 1024
    const val MESSAGE = "单个文件不能超过 50 MB"

    fun check(size: Long) {
        require(size <= MAX_BYTES) { MESSAGE }
    }

    // Providers may omit or misreport SIZE. Enforce the bound while copying too.
    fun copy(input: InputStream, output: OutputStream): Long {
        val buffer = ByteArray(64 * 1024)
        var total = 0L
        while (true) {
            val count = input.read(buffer)
            if (count < 0) return total
            check(total + count)
            output.write(buffer, 0, count)
            total += count
        }
    }
}
