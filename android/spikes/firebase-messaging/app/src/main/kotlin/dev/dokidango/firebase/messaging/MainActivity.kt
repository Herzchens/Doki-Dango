package dev.dokidango.firebase.messaging

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import org.json.JSONObject

class MainActivity : ComponentActivity() {
    private var projectId by mutableStateOf("")
    private var applicationId by mutableStateOf("")
    private var apiKey by mutableStateOf("")
    private var statusText by mutableStateOf("")

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val config = ConfigStore.load(this)
        projectId = config.projectId
        applicationId = config.applicationId
        apiKey = config.apiKey
        refreshStatus()

        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    HarnessScreen()
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        refreshStatus()
    }

    @Composable
    private fun HarnessScreen() {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(
                text = "Doki-Dango Firebase Messaging harness",
                style = MaterialTheme.typography.headlineSmall,
            )

            Text(
                "Kotlin/Compose Firebase Messaging harness. No google-services.json is embedded. " +
                    "Runtime FirebaseOptions are stored locally on this device.",
            )

            OutlinedTextField(
                value = projectId,
                onValueChange = { projectId = it },
                label = { Text("Firebase project ID") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
            )

            OutlinedTextField(
                value = applicationId,
                onValueChange = { applicationId = it },
                label = { Text("Firebase Android App ID (mobilesdk_app_id)") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
            )

            OutlinedTextField(
                value = apiKey,
                onValueChange = { apiKey = it },
                label = { Text("Firebase API key") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
            )

            Button(onClick = ::saveConfig, modifier = Modifier.fillMaxWidth()) {
                Text("Save runtime config")
            }
            Button(onClick = ::initializeFirebase, modifier = Modifier.fillMaxWidth()) {
                Text("Initialize DEFAULT FirebaseApp")
            }
            Button(onClick = ::registerWithFcm, modifier = Modifier.fillMaxWidth()) {
                Text("Register with FCM")
            }
            Button(onClick = ::requestNotificationPermission, modifier = Modifier.fillMaxWidth()) {
                Text("Request notification permission")
            }
            Button(onClick = ::clearEvidence, modifier = Modifier.fillMaxWidth()) {
                Text("Clear evidence")
            }
            Button(onClick = ::refreshStatus, modifier = Modifier.fillMaxWidth()) {
                Text("Refresh status")
            }

            Text(text = statusText, style = MaterialTheme.typography.bodyMedium)
        }
    }

    private fun saveConfig() {
        val config = ConfigStore.RuntimeConfig(
            projectId = projectId,
            applicationId = applicationId,
            apiKey = apiKey,
        ).normalized

        if (!config.isComplete()) {
            statusText = "Config incomplete: project ID, Firebase App ID, and API key are all required."
            return
        }

        ConfigStore.save(this, config)
        projectId = config.projectId
        applicationId = config.applicationId
        apiKey = config.apiKey

        EvidenceStore.write(
            context = this,
            operation = "runtime_config_save",
            outcome = "success",
            data = JSONObject().apply {
                put("projectIdPresent", true)
                put("applicationIdPresent", true)
                put("apiKeyPresent", true)
            },
        )
        refreshStatus()
    }

    private fun initializeFirebase() {
        val result = DokiFirebaseMessagingApplication.initializeDefaultFirebaseApp(
            application = application,
            trigger = "manual_ui",
        )
        statusText = "Firebase init result: " + result + "\n" + buildStatusText()
    }

    private fun registerWithFcm() {
        try {
            FirebaseApp.getInstance()
        } catch (_: IllegalStateException) {
            EvidenceStore.write(
                context = this,
                operation = "fcm_register",
                outcome = "skipped_default_app_missing",
                data = JSONObject(),
            )
            statusText = "DEFAULT FirebaseApp is not initialized."
            return
        }

        EvidenceStore.write(
            context = this,
            operation = "fcm_register",
            outcome = "started",
            data = JSONObject(),
        )

        FirebaseMessaging.getInstance()
            .register()
            .addOnCompleteListener { task ->
                if (task.isSuccessful) {
                    EvidenceStore.write(
                        context = this,
                        operation = "fcm_register",
                        outcome = "task_success",
                        data = JSONObject(),
                    )
                    statusText =
                        "register() completed. Waiting for onRegistered(FID) callback.\n" +
                            buildStatusText()
                } else {
                    val exception = task.exception
                    EvidenceStore.write(
                        context = this,
                        operation = "fcm_register",
                        outcome = "task_failure",
                        data = JSONObject(),
                        exception = exception,
                    )
                    statusText =
                        "register() failed: " +
                            (exception?.javaClass?.simpleName ?: "unknown error")
                }
            }
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < 33) {
            statusText = "POST_NOTIFICATIONS runtime permission is not required on this Android version."
            return
        }

        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            statusText = "Notification permission already granted."
            return
        }

        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)

        if (requestCode != NOTIFICATION_PERMISSION_REQUEST) {
            return
        }

        val granted =
            grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED

        EvidenceStore.write(
            context = this,
            operation = "notification_permission",
            outcome = if (granted) "granted" else "denied",
            data = JSONObject().apply {
                put("granted", granted)
            },
        )
        refreshStatus()
    }

    private fun clearEvidence() {
        EvidenceStore.clear(this)
        EvidenceStore.write(
            context = this,
            operation = "evidence_reset",
            outcome = "success",
            data = JSONObject(),
        )
        refreshStatus()
    }

    private fun refreshStatus() {
        statusText = buildStatusText()
    }

    private fun buildStatusText(): String {
        val config = ConfigStore.load(this)
        val firebaseInitialized = try {
            FirebaseApp.getInstance()
            true
        } catch (_: IllegalStateException) {
            false
        }

        val fid = FidStore.read(this)
        val notificationPermission =
            Build.VERSION.SDK_INT < 33 ||
                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED

        return buildString {
            appendLine("Config present: " + config.isComplete())
            appendLine("DEFAULT FirebaseApp: " + firebaseInitialized)
            appendLine("FID captured: " + fid.isNotEmpty())
            appendLine("FID fingerprint: " + FidStore.fingerprint(fid))
            appendLine("Notification permission: " + notificationPermission)
            append("Process foreground: " + DokiFirebaseMessagingApplication.isForeground())
        }
    }

    private companion object {
        const val NOTIFICATION_PERMISSION_REQUEST = 1001
    }
}
