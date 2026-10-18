package dev.dokidango.firebase.messaging.protocol

import org.json.JSONArray
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
        val cases = JSONArray(jsonText)

        assertTrue(
            "Expected at least 20 canonical fixture cases, found ${cases.length()}",
            cases.length() >= 20,
        )

        for (i in 0 until cases.length()) {
            val caseObj = cases.getJSONObject(i)
            val name = caseObj.getString("name")
            val valid = caseObj.getBoolean("valid")
            val envelopeJson = caseObj.getJSONObject("envelope")

            if (valid) {
                try {
                    val envelope = ProtocolEnvelope.fromJsonObject(envelopeJson)
                    assertEquals("Case '$name' protocol_version must be 1", 1L, envelope.protocolVersion)
                    assertTrue("Case '$name' messageId must not be empty", envelope.messageId.isNotEmpty())
                    assertTrue("Case '$name' pairId must not be empty", envelope.pairId.isNotEmpty())
                } catch (e: Exception) {
                    fail("Fixture case '$name' was expected to be valid, but failed: ${e.message}")
                }
            } else {
                try {
                    val envelope = ProtocolEnvelope.fromJsonObject(envelopeJson)
                    fail("Fixture case '$name' was expected to be invalid, but succeeded with envelope: $envelope")
                } catch (expected: ProtocolException) {
                    // Success: properly rejected by validation rules
                } catch (unexpected: Throwable) {
                    fail("Fixture case '$name' failed with unexpected exception type: ${unexpected.javaClass.name}")
                }
            }
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
        assertEquals(1L, envelope.protocolVersion)
        assertEquals("msg-unit-1", envelope.messageId)
        assertEquals(999L, envelope.senderSeq)
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
        assertEquals(1L, envelope.protocolVersion)
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
