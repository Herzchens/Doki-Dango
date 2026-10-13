package dev.dokidango.bharness

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build

internal object NotificationHelper {
    private const val CHANNEL_ID = "doki_b_synthetic"

    fun post(context: Context, testId: String): PostResult {
        val manager = context.getSystemService(NotificationManager::class.java)
            ?: return PostResult(
                notifyCallSucceeded = false,
                permissionGranted = false,
                status = "notification_manager_unavailable",
            )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Doki-Dango B synthetic tests",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description =
                        "Synthetic notifications used by the Doki-Dango B FCM feasibility harness."
                },
            )
        }

        val permissionGranted =
            Build.VERSION.SDK_INT < 33 ||
                context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED

        if (!permissionGranted) {
            return PostResult(
                notifyCallSucceeded = false,
                permissionGranted = false,
                status = "permission_not_granted",
            )
        }

        val pendingIntent = PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            Notification.Builder(context)
        }

        builder
            .setSmallIcon(android.R.drawable.stat_notify_more)
            .setContentTitle(testId)
            .setContentText("Doki-Dango synthetic FCM delivery")
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .setWhen(System.currentTimeMillis())

        return try {
            manager.notify(positiveId(testId), builder.build())
            PostResult(
                notifyCallSucceeded = true,
                permissionGranted = true,
                status = "posted",
            )
        } catch (_: SecurityException) {
            PostResult(
                notifyCallSucceeded = false,
                permissionGranted = permissionGranted,
                status = "security_exception",
            )
        }
    }

    private fun positiveId(value: String): Int = value.hashCode() and Int.MAX_VALUE

    data class PostResult(
        val notifyCallSucceeded: Boolean,
        val permissionGranted: Boolean,
        val status: String,
    )
}
