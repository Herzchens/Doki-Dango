package dev.dokidango.firebase.messaging

import android.os.Process
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import org.json.JSONObject

class DokiMessagingService : FirebaseMessagingService() {
    override fun onRegistered(installationId: String) {
        val data = JSONObject()

        try {
            FidStore.save(this, installationId)
            data.put("fidLength", installationId.length)
            data.put("fidFingerprint", FidStore.fingerprint(installationId))
            EvidenceStore.write(
                context = this,
                operation = "onRegistered",
                outcome = "success",
                data = data,
            )
        } catch (exception: Throwable) {
            EvidenceStore.write(
                context = this,
                operation = "onRegistered",
                outcome = "exception",
                data = data,
                exception = exception,
            )
        }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val payload = message.data
        val testId = payload[TEST_ID_KEY]

        if (testId == null || !testId.startsWith(TEST_ID_PREFIX)) {
            EvidenceStore.write(
                context = this,
                operation = "onMessageReceived",
                outcome = "ignored_non_test_payload",
                data = JSONObject().apply {
                    put("dataKeyCount", payload.size)
                },
            )
            return
        }

        EvidenceStore.write(
            context = this,
            operation = "onMessageReceived",
            outcome = "success",
            data = JSONObject().apply {
                put("testId", testId)
                put("foreground", DokiFirebaseMessagingApplication.isForeground())
                put("pid", Process.myPid())
                put("dataKeyCount", payload.size)
            },
        )

        val postResult = NotificationHelper.post(this, testId)
        EvidenceStore.write(
            context = this,
            operation = "local_notification",
            outcome = if (postResult.notifyCallSucceeded && postResult.permissionGranted) {
                "posted"
            } else {
                "blocked"
            },
            data = JSONObject().apply {
                put("testId", testId)
                put("notifyCallSucceeded", postResult.notifyCallSucceeded)
                put("permissionGranted", postResult.permissionGranted)
                put("status", postResult.status)
            },
        )
    }

    override fun onDeletedMessages() {
        EvidenceStore.write(
            context = this,
            operation = "onDeletedMessages",
            outcome = "observed",
            data = JSONObject(),
        )
    }

    private companion object {
        const val TEST_ID_KEY = "doki_test_id"
        const val TEST_ID_PREFIX = "DOKI-"
    }
}
