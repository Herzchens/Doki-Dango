package dev.dokidango.bharness

import android.content.Context
import com.google.firebase.FirebaseOptions

internal object ConfigStore {
    private const val PREFS = "doki_b_runtime"
    private const val KEY_PROJECT_ID = "project_id"
    private const val KEY_APPLICATION_ID = "application_id"
    private const val KEY_API_KEY = "api_key"

    fun load(context: Context): RuntimeConfig {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return RuntimeConfig(
            projectId = prefs.getString(KEY_PROJECT_ID, "").orEmpty(),
            applicationId = prefs.getString(KEY_APPLICATION_ID, "").orEmpty(),
            apiKey = prefs.getString(KEY_API_KEY, "").orEmpty(),
        )
    }

    fun save(context: Context, config: RuntimeConfig) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_PROJECT_ID, config.projectId)
            .putString(KEY_APPLICATION_ID, config.applicationId)
            .putString(KEY_API_KEY, config.apiKey)
            .apply()
    }

    data class RuntimeConfig(
        val projectId: String,
        val applicationId: String,
        val apiKey: String,
    ) {
        val normalized: RuntimeConfig
            get() = RuntimeConfig(
                projectId = projectId.trim(),
                applicationId = applicationId.trim(),
                apiKey = apiKey.trim(),
            )

        fun isComplete(): Boolean {
            val value = normalized
            return value.projectId.isNotEmpty() &&
                value.applicationId.isNotEmpty() &&
                value.apiKey.isNotEmpty()
        }

        fun toFirebaseOptions(): FirebaseOptions {
            val value = normalized
            return FirebaseOptions.Builder()
                .setProjectId(value.projectId)
                .setApplicationId(value.applicationId)
                .setApiKey(value.apiKey)
                .build()
        }
    }
}
