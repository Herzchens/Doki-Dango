package dev.dokidango.bharness

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.nio.charset.StandardCharsets
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

internal object EvidenceStore {
    private const val FILE_NAME = "b-evidence.jsonl"
    private val lock = Any()

    fun write(
        context: Context,
        operation: String,
        outcome: String,
        data: JSONObject,
        exception: Throwable? = null,
    ) {
        try {
            val record = JSONObject().apply {
                put("timestampUtc", utcTimestamp())
                put("phase", "B")
                put("operation", operation)
                put("outcome", outcome)
                put("data", data)
                if (exception == null) {
                    put("exceptionType", JSONObject.NULL)
                    put("exceptionMessage", JSONObject.NULL)
                } else {
                    put("exceptionType", exception.javaClass.name)
                    put("exceptionMessage", safeExceptionMessage(context, exception))
                }
            }

            val line = (record.toString() + "\n").toByteArray(StandardCharsets.UTF_8)
            val target = File(context.filesDir, FILE_NAME)

            synchronized(lock) {
                FileOutputStream(target, true).use { stream ->
                    stream.write(line)
                    stream.flush()
                }
            }
        } catch (_: Exception) {
            // Evidence collection must never crash the probe path.
        }
    }

    fun clear(context: Context) {
        val target = File(context.filesDir, FILE_NAME)
        synchronized(lock) {
            if (target.exists()) {
                target.delete()
            }
        }
    }

    private fun utcTimestamp(): String =
        SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }.format(Date())

    private fun safeExceptionMessage(
        context: Context,
        exception: Throwable,
    ): String {
        var message = exception.message.orEmpty()
        val config = ConfigStore.load(context)

        listOf(config.apiKey, config.applicationId)
            .filter { it.isNotEmpty() }
            .forEach { secret ->
                message = message.replace(secret, "<redacted>")
            }

        message = message.replace('\r', ' ').replace('\n', ' ').trim()
        return if (message.length > 500) message.substring(0, 500) else message
    }
}
