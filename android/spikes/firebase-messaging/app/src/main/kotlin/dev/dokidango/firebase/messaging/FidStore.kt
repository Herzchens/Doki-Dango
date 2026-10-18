package dev.dokidango.firebase.messaging

import android.content.Context
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.charset.StandardCharsets
import java.security.MessageDigest

internal object FidStore {
    private const val FILE_NAME = "firebase-fid.txt"

    @Throws(Exception::class)
    fun save(context: Context, fid: String) {
        val target = File(context.filesDir, FILE_NAME)
        val temporary = File(context.filesDir, FILE_NAME + ".tmp")
        val bytes = fid.toByteArray(StandardCharsets.UTF_8)

        FileOutputStream(temporary, false).use { stream ->
            stream.write(bytes)
            stream.flush()
            stream.fd.sync()
        }

        if (target.exists() && !target.delete()) {
            throw IllegalStateException("Could not replace existing FID file")
        }
        if (!temporary.renameTo(target)) {
            throw IllegalStateException("Could not atomically publish FID file")
        }
    }

    fun read(context: Context): String {
        return try {
            val file = File(context.filesDir, FILE_NAME)
            if (!file.isFile) {
                return ""
            }

            FileInputStream(file).use { input ->
                ByteArrayOutputStream().use { output ->
                    val buffer = ByteArray(256)
                    while (true) {
                        val count = input.read(buffer)
                        if (count == -1) {
                            break
                        }
                        output.write(buffer, 0, count)
                    }
                    output.toString(StandardCharsets.UTF_8.name()).trim()
                }
            }
        } catch (_: Exception) {
            ""
        }
    }

    fun fingerprint(fid: String): String {
        if (fid.isEmpty()) {
            return "none"
        }

        val hash = MessageDigest.getInstance("SHA-256")
            .digest(fid.toByteArray(StandardCharsets.UTF_8))

        return hash.take(8).joinToString(separator = "") { byte ->
            "%02x".format(byte)
        }
    }
}
