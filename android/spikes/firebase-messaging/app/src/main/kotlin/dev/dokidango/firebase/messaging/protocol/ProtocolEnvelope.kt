package dev.dokidango.firebase.messaging.protocol

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.json.JSONObject

data class ProtocolEnvelope(
    val protocolVersion: UInt,
    val messageId: String,
    val pairId: String,
    val kind: String,
    val sourceId: String,
    val sourceRevision: ULong,
    val sentAt: String,
    val expiresAt: String,
    val payload: JsonElement,
    val senderSeq: ULong? = null,
) {
    companion object {
        const val CURRENT_VERSION: UInt = 1u

        @Throws(ProtocolException::class)
        fun fromJson(jsonStr: String): ProtocolEnvelope {
            val element = try {
                Json.parseToJsonElement(jsonStr)
            } catch (e: Exception) {
                throw ProtocolException("Malformed JSON: ${e.message}", e)
            }
            if (element !is JsonObject) {
                throw ProtocolException("Root JSON must be an object, got: ${element.javaClass.simpleName}")
            }
            return fromJsonObject(element)
        }

        @Throws(ProtocolException::class)
        fun fromJsonObject(json: JsonObject): ProtocolEnvelope {
            if (!json.containsKey("protocol_version")) {
                throw ProtocolException("Missing required field: protocol_version")
            }
            val versionElem = json["protocol_version"]
            if (versionElem !is JsonPrimitive || versionElem.isString) {
                throw ProtocolException("protocol_version must be an unquoted integer, got: $versionElem")
            }
            if (versionElem.content != "1") {
                throw ProtocolException("Unsupported protocol version: ${versionElem.content} (expected 1)")
            }

            val messageId = requireNonEmptyString(json, "message_id")
            val pairId = requireNonEmptyString(json, "pair_id")
            val kind = requireNonEmptyString(json, "kind")
            val sourceId = requireNonEmptyString(json, "source_id")

            val sourceRevision = parseU64(json["source_revision"], "source_revision")

            val sentAt = requireNonEmptyString(json, "sent_at")
            val expiresAt = requireNonEmptyString(json, "expires_at")

            if (!json.containsKey("payload")) {
                throw ProtocolException("Missing required field: payload")
            }
            val payload = json["payload"] ?: JsonNull

            val senderSeq = if (json.containsKey("sender_seq")) {
                val seqElem = json["sender_seq"]
                if (seqElem is JsonNull) {
                    throw ProtocolException("sender_seq cannot be null; omit the field if absent")
                }
                parseU64(seqElem, "sender_seq")
            } else {
                null
            }

            // Unknown extra fields are safely tolerated and ignored.
            return ProtocolEnvelope(
                protocolVersion = CURRENT_VERSION,
                messageId = messageId,
                pairId = pairId,
                kind = kind,
                sourceId = sourceId,
                sourceRevision = sourceRevision,
                sentAt = sentAt,
                expiresAt = expiresAt,
                payload = payload,
                senderSeq = senderSeq,
            )
        }

        @Throws(ProtocolException::class)
        fun fromJsonObject(json: JSONObject): ProtocolEnvelope {
            return fromJson(json.toString())
        }

        private fun requireNonEmptyString(json: JsonObject, field: String): String {
            if (!json.containsKey(field)) {
                throw ProtocolException("Missing required field: $field")
            }
            val elem = json[field]
            if (elem !is JsonPrimitive || !elem.isString) {
                throw ProtocolException("Field '$field' must be a string, got: $elem")
            }
            if (elem.content.trim().isEmpty()) {
                throw ProtocolException("Field '$field' cannot be empty or whitespace")
            }
            return elem.content
        }

        private fun parseU64(elem: JsonElement?, field: String): ULong {
            if (elem == null) {
                throw ProtocolException("Missing required field: $field")
            }
            if (elem !is JsonPrimitive || elem.isString) {
                throw ProtocolException("Field '$field' must be an unquoted integer, got: $elem")
            }
            val raw = elem.content
            if (raw.isEmpty() || !raw.all { it in '0'..'9' }) {
                throw ProtocolException("Field '$field' must be an unsigned integer, got: $raw")
            }
            return raw.toULongOrNull()
                ?: throw ProtocolException("Field '$field' exceeds maximum unsigned 64-bit integer: $raw")
        }
    }
}

class ProtocolException(message: String, cause: Throwable? = null) : Exception(message, cause)
