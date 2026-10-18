package dev.dokidango.firebase.messaging.protocol

import org.json.JSONObject

data class ProtocolEnvelope(
    val protocolVersion: Long,
    val messageId: String,
    val pairId: String,
    val kind: String,
    val sourceId: String,
    val sourceRevision: Long,
    val sentAt: String,
    val expiresAt: String,
    val payload: Any?,
    val senderSeq: Long? = null,
) {
    companion object {
        const val CURRENT_VERSION: Long = 1L

        @Throws(ProtocolException::class)
        fun fromJson(jsonStr: String): ProtocolEnvelope {
            val json = try {
                JSONObject(jsonStr)
            } catch (e: Exception) {
                throw ProtocolException("Malformed JSON: ${e.message}", e)
            }
            return fromJsonObject(json)
        }

        @Throws(ProtocolException::class)
        fun fromJsonObject(json: JSONObject): ProtocolEnvelope {
            if (!json.has("protocol_version")) {
                throw ProtocolException("Missing required field: protocol_version")
            }
            val versionObj = json.opt("protocol_version")
            if (versionObj !is Number) {
                throw ProtocolException("protocol_version must be a number, got: ${versionObj?.javaClass?.simpleName}")
            }
            val protocolVersion = versionObj.toLong()
            if (protocolVersion != CURRENT_VERSION) {
                throw ProtocolException("Unsupported protocol version: $protocolVersion (expected $CURRENT_VERSION)")
            }

            val messageId = requireNonEmptyString(json, "message_id")
            val pairId = requireNonEmptyString(json, "pair_id")
            val kind = requireNonEmptyString(json, "kind")
            val sourceId = requireNonEmptyString(json, "source_id")

            if (!json.has("source_revision")) {
                throw ProtocolException("Missing required field: source_revision")
            }
            val sourceRevisionObj = json.opt("source_revision")
            if (sourceRevisionObj !is Number) {
                throw ProtocolException("source_revision must be a number, got: ${sourceRevisionObj?.javaClass?.simpleName}")
            }
            val sourceRevision = sourceRevisionObj.toLong()
            if (sourceRevision < 0) {
                throw ProtocolException("source_revision must be non-negative: $sourceRevision")
            }

            val sentAt = requireNonEmptyString(json, "sent_at")
            val expiresAt = requireNonEmptyString(json, "expires_at")

            if (!json.has("payload")) {
                throw ProtocolException("Missing required field: payload")
            }
            val payload = json.opt("payload")

            val senderSeq = if (json.has("sender_seq")) {
                val seqObj = json.opt("sender_seq")
                if (seqObj == null || seqObj == JSONObject.NULL) {
                    null
                } else if (seqObj !is Number) {
                    throw ProtocolException("sender_seq must be a number, got: ${seqObj.javaClass.simpleName}")
                } else {
                    val seqVal = seqObj.toLong()
                    if (seqVal < 0) {
                        throw ProtocolException("sender_seq must be non-negative: $seqVal")
                    }
                    seqVal
                }
            } else {
                null
            }

            // Unknown extra fields are safely tolerated and ignored.
            return ProtocolEnvelope(
                protocolVersion = protocolVersion,
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

        private fun requireNonEmptyString(json: JSONObject, field: String): String {
            if (!json.has(field)) {
                throw ProtocolException("Missing required field: $field")
            }
            val valueObj = json.opt(field)
            if (valueObj !is String) {
                throw ProtocolException("Field $field must be a string, got: ${valueObj?.javaClass?.simpleName}")
            }
            if (valueObj.trim().isEmpty()) {
                throw ProtocolException("Field $field cannot be empty or whitespace")
            }
            return valueObj
        }
    }
}

class ProtocolException(message: String, cause: Throwable? = null) : Exception(message, cause)
