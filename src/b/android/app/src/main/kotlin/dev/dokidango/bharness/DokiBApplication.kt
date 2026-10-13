package dev.dokidango.bharness

import android.app.Activity
import android.app.Application
import android.os.Bundle
import android.os.Process
import com.google.firebase.FirebaseApp
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicInteger

class DokiBApplication : Application(), Application.ActivityLifecycleCallbacks {
    override fun onCreate() {
        super.onCreate()
        registerActivityLifecycleCallbacks(this)

        EvidenceStore.write(
            context = this,
            operation = "process_start",
            outcome = "observed",
            data = JSONObject().apply {
                put("pid", Process.myPid())
                put("configPresent", ConfigStore.load(this@DokiBApplication).isComplete())
            },
        )

        initializeDefaultFirebaseApp(this, "application_on_create")
    }

    override fun onActivityStarted(activity: Activity) {
        startedActivities.incrementAndGet()
    }

    override fun onActivityStopped(activity: Activity) {
        startedActivities.updateAndGet { current -> maxOf(0, current - 1) }
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
    override fun onActivityResumed(activity: Activity) = Unit
    override fun onActivityPaused(activity: Activity) = Unit
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
    override fun onActivityDestroyed(activity: Activity) = Unit

    enum class InitResult {
        SUCCESS,
        ALREADY_INITIALIZED,
        MISSING_CONFIG,
        FAILED,
    }

    companion object {
        private val startedActivities = AtomicInteger()

        fun isForeground(): Boolean = startedActivities.get() > 0

        fun initializeDefaultFirebaseApp(
            application: Application,
            trigger: String,
        ): InitResult {
            val config = ConfigStore.load(application)
            val data = JSONObject().apply {
                put("trigger", trigger)
                put("configPresent", config.isComplete())
            }

            if (!config.isComplete()) {
                EvidenceStore.write(
                    context = application,
                    operation = "firebase_default_init",
                    outcome = "skipped_missing_config",
                    data = data,
                )
                return InitResult.MISSING_CONFIG
            }

            try {
                FirebaseApp.getInstance()
                EvidenceStore.write(
                    context = application,
                    operation = "firebase_default_init",
                    outcome = "already_initialized",
                    data = data,
                )
                return InitResult.ALREADY_INITIALIZED
            } catch (_: IllegalStateException) {
                // Expected before the runtime DEFAULT app is created.
            }

            return try {
                val app = FirebaseApp.initializeApp(application, config.toFirebaseOptions())
                if (app == null) {
                    EvidenceStore.write(
                        context = application,
                        operation = "firebase_default_init",
                        outcome = "failed_null",
                        data = data,
                    )
                    InitResult.FAILED
                } else {
                    EvidenceStore.write(
                        context = application,
                        operation = "firebase_default_init",
                        outcome = "success",
                        data = data,
                    )
                    InitResult.SUCCESS
                }
            } catch (exception: Throwable) {
                EvidenceStore.write(
                    context = application,
                    operation = "firebase_default_init",
                    outcome = "exception",
                    data = data,
                    exception = exception,
                )
                InitResult.FAILED
            }
        }
    }
}
