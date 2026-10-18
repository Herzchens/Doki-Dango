package dev.dokidango.firebase.messaging.protocol

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.io.InputStream

class ProtocolContractTest {

    private fun loadFixtureInputStream(): InputStream {
        val resourceStream = ProtocolContractTest::class.java.classLoader?.getResourceAsStream("v1.json")
            ?: ProtocolContractTest::class.java.getResourceAsStream("/v1.json")
        if (resourceStream != null) {
            return resourceStream
        }

        // Direct repository path fallback for IDE / standalone runners
        val relativeFile = File("../../../../shared/protocol/fixtures/v1.json")
        if (relativeFile.exists()) {
            return relativeFile.inputStream()
        }

        val projectRelativeFile = File("shared/protocol/fixtures/v1.json")
        if (projectRelativeFile.exists()) {
            return projectRelativeFile.inputStream()
        }

        throw IllegalStateException("Unable to locate shared protocol fixture v1.json")
    }

    @Test
    fun validatesAllCanonicalV1Fixtures() {
        val jsonText = loadFixtureInputStream().bufferedReader().use { it.readText() }
        val cases = Json.parseToJsonElement(jsonText).jsonArray

        assertTrue(
            "Expected at least 35 canonical fixture cases, found ${cases.size}",
            cases.size >= 35,
        )

        for (caseElement in cases) {
            val caseObj = caseElement.jsonObject
            val name = caseObj["name"]!!.jsonPrimitive.content
            val valid = caseObj["valid"]!!.jsonPrimitive.boolean
            val envelopeJson = caseObj["envelope"]!!.jsonObject
            val envelopeJsonStr = envelopeJson.toString()

            if (valid) {
                try {
                    val envelope = ProtocolEnvelope.fromJson(envelopeJsonStr)
                    assertEquals("Case '$name' protocol_version must be 1", 1u, envelope.protocolVersion)
                    assertTrue("Case '$name' messageId must not be empty", envelope.messageId.isNotEmpty())
                    assertTrue("Case '$name' pairId must not be empty", envelope.pairId.isNotEmpty())

                    // Also verify org.json bridge
                    val bridgeEnvelope = ProtocolEnvelope.fromJsonObject(JSONObject(envelopeJsonStr))
                    assertEquals("Bridge case '$name' protocol_version must be 1", 1u, bridgeEnvelope.protocolVersion)
                } catch (e: Exception) {
                    fail("Fixture case '$name' was expected to be valid, but failed: ${e.message}")
                }
            } else {
                try {
                    val envelope = ProtocolEnvelope.fromJson(envelopeJsonStr)
                    fail("Fixture case '$name' was expected to be invalid, but succeeded with envelope: $envelope")
                } catch (expected: ProtocolException) {
                    // Success: properly rejected by validation rules
                } catch (unexpected: Throwable) {
                    fail("Fixture case '$name' failed with unexpected exception type: ${unexpected.javaClass.name}")
                }

                // Verify org.json bridge also rejects
                try {
                    ProtocolEnvelope.fromJsonObject(JSONObject(envelopeJsonStr))
                    fail("Bridge fixture case '$name' was expected to be invalid, but succeeded")
                } catch (expected: ProtocolException) {
                    // Success
                } catch (unexpected: Throwable) {
                    fail("Bridge fixture case '$name' failed with unexpected exception type: ${unexpected.javaClass.name}")
                }
            }
        }
    }

    @Test
    fun boundaryAcceptsULongMax() {
        val json = """
            {
                "protocol_version": 1,
                "message_id": "msg-max",
                "pair_id": "pair-1",
                "kind": "notification.upsert",
                "source_id": "source-1",
                "source_revision": 18446744073709551615,
                "sent_at": "2026-10-18T10:00:00Z",
                "expires_at": "2026-10-18T10:05:00Z",
                "payload": {},
                "sender_seq": 18446744073709551615
            }
        """.trimIndent()

        val env = ProtocolEnvelope.fromJson(json)
        assertEquals(ULong.MAX_VALUE, env.sourceRevision)
        assertEquals(ULong.MAX_VALUE, env.senderSeq)
    }

    @Test
    fun boundaryRejectsULongOverflow() {
        val jsonRev = """
            {
                "protocol_version": 1,
                "message_id": "msg-ovf",
                "pair_id": "pair-1",
                "kind": "notification.upsert",
                "source_id": "source-1",
                "source_revision": 18446744073709551616,
                "sent_at": "2026-10-18T10:00:00Z",
                "expires_at": "2026-10-18T10:05:00Z",
                "payload": {}
            }
        """.trimIndent()
        try {
            ProtocolEnvelope.fromJson(jsonRev)
            fail("Expected ProtocolException for source_revision overflow")
        } catch (expected: ProtocolException) {
            // Success
        }

        val jsonSeq = """
            {
                "protocol_version": 1,
                "message_id": "msg-ovf",
                "pair_id": "pair-1",
                "kind": "notification.upsert",
                "source_id": "source-1",
                "source_revision": 1,
                "sent_at": "2026-10-18T10:00:00Z",
                "expires_at": "2026-10-18T10:05:00Z",
                "payload": {},
                "sender_seq": 18446744073709551616
            }
        """.trimIndent()
        try {
            ProtocolEnvelope.fromJson(jsonSeq)
            fail("Expected ProtocolException for sender_seq overflow")
        } catch (expected: ProtocolException) {
            // Success
        }
    }

    @Test(expected = ProtocolException::class)
    fun boundaryRejectsExplicitNullSenderSeq() {
        val json = """
            {
                "protocol_version": 1,
                "message_id": "msg-null",
                "pair_id": "pair-1",
                "kind": "notification.upsert",
                "source_id": "source-1",
                "source_revision": 1,
                "sent_at": "2026-10-18T10:00:00Z",
                "expires_at": "2026-10-18T10:05:00Z",
                "payload": {},
                "sender_seq": null
            }
        """.trimIndent()

        ProtocolEnvelope.fromJson(json)
    }

    @Test
    fun boundaryRejectsFractionalNumbers() {
        val jsonVer = """
            {
                "protocol_version": 1.5,
                "message_id": "msg-frac",
                "pair_id": "pair-1",
                "kind": "notification.upsert",
                "source_id": "source-1",
                "source_revision": 1,
                "sent_at": "2026-10-18T10:00:00Z",
                "expires_at": "2026-10-18T10:05:00Z",
                "payload": {}
            }
        """.trimIndent()
        try {
            ProtocolEnvelope.fromJson(jsonVer)
            fail("Expected ProtocolException for fractional protocol_version")
        } catch (expected: ProtocolException) {
            // Success
        }

        val jsonRev = """
            {
                "protocol_version": 1,
                "message_id": "msg-frac",
                "pair_id": "pair-1",
                "kind": "notification.upsert",
                "source_id": "source-1",
                "source_revision": 1.5,
                "sent_at": "2026-10-18T10:00:00Z",
                "expires_at": "2026-10-18T10:05:00Z",
                "payload": {}
            }
        """.trimIndent()
        try {
            ProtocolEnvelope.fromJson(jsonRev)
            fail("Expected ProtocolException for fractional source_revision")
        } catch (expected: ProtocolException) {
            // Success
        }

        val jsonSeq = """
            {
                "protocol_version": 1,
                "message_id": "msg-frac",
                "pair_id": "pair-1",
                "kind": "notification.upsert",
                "source_id": "source-1",
                "source_revision": 1,
                "sent_at": "2026-10-18T10:00:00Z",
                "expires_at": "2026-10-18T10:05:00Z",
                "payload": {},
                "sender_seq": 1.5
            }
        """.trimIndent()
        try {
            ProtocolEnvelope.fromJson(jsonSeq)
            fail("Expected ProtocolException for fractional sender_seq")
        } catch (expected: ProtocolException) {
            // Success
        }
    }

    @Test
    fun parsesValidEnvelopeWithOptionalSenderSeq() {
        val json = """
            {
                "protocol_version": 1,
                "message_id": "msg-unit-1",
                "pair_id": "pair-unit-1",
                "kind": "notification.upsert",
                "source_id": "src-unit",
                "source_revision": 100,
                "sent_at": "2026-10-18T12:00:00Z",
                "expires_at": "2026-10-18T12:05:00Z",
                "payload": {"key": "value"},
                "sender_seq": 999
            }
        """.trimIndent()

        val envelope = ProtocolEnvelope.fromJson(json)
        assertEquals(1u, envelope.protocolVersion)
        assertEquals("msg-unit-1", envelope.messageId)
        assertEquals(999uL, envelope.senderSeq)
    }

    @Test
    fun parsesValidEnvelopeWithoutSenderSeq() {
        val json = """
            {
                "protocol_version": 1,
                "message_id": "msg-unit-2",
                "pair_id": "pair-unit-1",
                "kind": "notification.upsert",
                "source_id": "src-unit",
                "source_revision": 101,
                "sent_at": "2026-10-18T12:00:00Z",
                "expires_at": "2026-10-18T12:05:00Z",
                "payload": "string payload"
            }
        """.trimIndent()

        val envelope = ProtocolEnvelope.fromJson(json)
        assertEquals(1u, envelope.protocolVersion)
        assertNull(envelope.senderSeq)
        assertNotNull(envelope.payload)
    }

    @Test(expected = ProtocolException::class)
    fun rejectsWhitespaceStringField() {
        val json = """
            {
                "protocol_version": 1,
                "message_id": "   ",
                "pair_id": "pair-unit-1",
                "kind": "notification.upsert",
                "source_id": "src-unit",
                "source_revision": 102,
                "sent_at": "2026-10-18T12:00:00Z",
                "expires_at": "2026-10-18T12:05:00Z",
                "payload": {}
            }
        """.trimIndent()

        ProtocolEnvelope.fromJson(json)
    }
}
