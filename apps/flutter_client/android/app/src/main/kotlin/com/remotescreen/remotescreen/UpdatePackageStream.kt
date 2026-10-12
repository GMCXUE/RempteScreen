package com.remotescreen.remotescreen

import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest

/** Recheck the exact bytes handed to PackageInstaller, not only the earlier cache file. */
internal object UpdatePackageStream {
    fun copyVerified(input: InputStream, output: OutputStream, expectedSize: Long, sha256: String) {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(65536)
        var size = 0L
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            size += count
            require(size <= expectedSize) { "安装包大小不符，请重新下载" }
            digest.update(buffer, 0, count)
            output.write(buffer, 0, count)
        }
        require(size == expectedSize && digest.digest().joinToString("") { "%02x".format(it) } == sha256) {
            "安装包校验失败，请重新下载"
        }
    }
}
