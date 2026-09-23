package com.shaunkleyn.service_keeper

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.SharedPreferences
import androidx.core.app.NotificationCompat
import androidx.work.*
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

class MonitorWorker(context: Context, params: WorkerParameters) :
    Worker(context, params) {

    companion object {
        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val SERVICES_KEY = "flutter.monitored_services"
        private const val AUDIT_KEY = "flutter.pending_audit_events"
        private const val CHANNEL_ID = "service_keeper_restarts"
        private const val CHANNEL_NAME = "Service Restarts"
        private const val GROUP_KEY = "com.shaunkleyn.service_keeper.RESTARTS"
        private const val SUMMARY_ID = 999
        private var notifId = 1000
        private val packageLocks = mutableMapOf<String, Any>()
        private val recentAppRelaunches = mutableMapOf<String, Long>()

        @Synchronized
        private fun packageLock(packageName: String): Any =
            packageLocks.getOrPut(packageName) { Any() }

        @Synchronized
        private fun markAppRelaunched(packageName: String) {
            recentAppRelaunches[packageName] = System.currentTimeMillis()
        }

        @Synchronized
        private fun wasAppRecentlyRelaunched(packageName: String): Boolean {
            val launchedAt = recentAppRelaunches[packageName] ?: return false
            return System.currentTimeMillis() - launchedAt < 60_000L
        }

        fun schedule(context: Context, workTag: String, intervalMinutes: Long, inputData: Data) {
            val request = PeriodicWorkRequestBuilder<MonitorWorker>(
                intervalMinutes, TimeUnit.MINUTES
            )
                .addTag(workTag)
                .setInputData(inputData)
                .setConstraints(Constraints.NONE)
                .build()

            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                workTag,
                ExistingPeriodicWorkPolicy.UPDATE,
                request
            )
        }

        fun scheduleOnce(context: Context, workTag: String, delayMinutes: Long, inputData: Data) {
            val request = OneTimeWorkRequestBuilder<MonitorWorker>()
                .addTag(workTag)
                .setInputData(inputData)
                .setInitialDelay(delayMinutes, TimeUnit.MINUTES)
                .build()

            WorkManager.getInstance(context).enqueueUniqueWork(
                "${workTag}_once",
                ExistingWorkPolicy.REPLACE,
                request
            )
        }

        fun cancel(context: Context, workTag: String) {
            WorkManager.getInstance(context).cancelAllWorkByTag(workTag)
        }

        fun runNow(context: Context, workTag: String, inputData: Data) {
            val request = OneTimeWorkRequestBuilder<MonitorWorker>()
                .addTag(workTag)
                .setInputData(inputData)
                .build()

            WorkManager.getInstance(context).enqueueUniqueWork(
                "${workTag}_now",
                ExistingWorkPolicy.REPLACE,
                request
            )
        }

        fun scheduleAllFromPrefs(context: Context) {
            val prefs: SharedPreferences =
                context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val raw = prefs.getString(SERVICES_KEY, null) ?: return
            try {
                val arr = JSONArray(raw)
                for (i in 0 until arr.length()) {
                    val obj = arr.getJSONObject(i)
                    if (!obj.optBoolean("enabled", true)) continue
                    val pkg = obj.getString("packageName")
                    val cls = obj.getString("serviceClass")
                    val label = obj.getString("displayLabel")
                    val appName = obj.optString("appName", label)
                    val interval = obj.optInt("intervalMinutes", 15).toLong()
                    val tag = "${pkg}_${cls.replace('.', '_')}"
                    val appRestartEnabled = obj.optBoolean("appRestartEnabled", false)
                    val data = Data.Builder()
                        .putString("packageName", pkg)
                        .putString("serviceClass", cls)
                        .putString("displayLabel", label)
                        .putString("appName", appName)
                        .putLong("intervalMinutes", interval)
                        .putBoolean("selfChain", interval < 15)
                        .putBoolean("appRestartEnabled", appRestartEnabled)
                        .build()

                    if (interval >= 15) {
                        schedule(context, tag, interval, data)
                    } else {
                        scheduleOnce(context, tag, interval, data)
                    }
                }
            } catch (_: Exception) { }
        }
    }

    override fun doWork(): Result {
        val pkg = inputData.getString("packageName") ?: return Result.failure()
        val cls = inputData.getString("serviceClass") ?: return Result.failure()
        val label = inputData.getString("displayLabel") ?: pkg
        val appName = inputData.getString("appName") ?: label
        val selfChain = inputData.getBoolean("selfChain", false)
        val intervalMinutes = inputData.getLong("intervalMinutes", 15L)
        val appRestartEnabled = inputData.getBoolean("appRestartEnabled", false)

        if (!ShizukuExecutor.isReady()) return Result.retry()

        synchronized(packageLock(pkg)) {
            recoverPackage(
                pkg,
                intervalMinutes,
                FallbackCandidate(cls, label, appName, appRestartEnabled)
            )
        }

        // Self-chain for sub-15-min intervals
        if (selfChain) {
            val tag = "${pkg}_${cls.replace('.', '_')}"
            scheduleOnce(applicationContext, tag, intervalMinutes, inputData)
        }

        return Result.success()
    }

    private data class FallbackCandidate(
        val serviceClass: String,
        val label: String,
        val appName: String,
        val appRestartEnabled: Boolean
    )

    private data class WorkerCandidate(
        val serviceClass: String,
        val label: String,
        val appName: String,
        val appRestartEnabled: Boolean,
        val notifEnabled: Boolean
    )

    private fun recoverPackage(
        packageName: String,
        intervalMinutes: Long,
        fallback: FallbackCandidate
    ) {
        val candidates = monitoredCandidatesForPackage(packageName).ifEmpty {
            listOf(
                WorkerCandidate(
                    fallback.serviceClass,
                    fallback.label,
                    fallback.appName,
                    fallback.appRestartEnabled,
                    notificationsEnabledFor(packageName, fallback.serviceClass)
                )
            )
        }
        val failed = mutableListOf<WorkerCandidate>()

        for (candidate in candidates) {
            if (ShizukuExecutor.isServiceRunning(packageName, candidate.serviceClass)) continue

            appendAuditEvent(
                packageName,
                candidate.serviceClass,
                candidate.label,
                "DETECTED_STOPPED",
                "AUTOMATIC",
                "Worker check detected service stopped (interval: ${intervalMinutes} min)"
            )
            appendAuditEvent(
                packageName,
                candidate.serviceClass,
                candidate.label,
                "RESTART_ATTEMPTED",
                "AUTOMATIC",
                "Worker direct restart attempt (app restart fallback: ${if (candidate.appRestartEnabled) "on" else "off"})"
            )
            val start = ShizukuExecutor.startServiceDetailed(
                packageName,
                candidate.serviceClass,
                appRestartEnabled = false
            )
            if (start.ok) {
                appendAuditEvent(packageName, candidate.serviceClass, candidate.label, "RESTART_SUCCESS", "AUTOMATIC", start.detail)
                if (candidate.notifEnabled) {
                    sendNotification(candidate.appName, "Background service was stopped and has been restarted.")
                }
            } else if (candidate.appRestartEnabled) {
                failed += candidate
            } else {
                appendAuditEvent(packageName, candidate.serviceClass, candidate.label, "RESTART_FAILED", "AUTOMATIC", start.detail)
            }
        }

        if (failed.isEmpty() || wasAppRecentlyRelaunched(packageName)) return

        if (!DeviceIdleChecker.isIdleFromPrefs(applicationContext)) {
            for (candidate in failed) {
                PendingRelaunchQueue.enqueue(
                    applicationContext,
                    PendingRelaunchQueue.Entry(
                        packageName,
                        candidate.serviceClass,
                        candidate.label,
                        candidate.notifEnabled
                    )
                )
            }
            return
        }

        val appStarted = ShizukuExecutor.restartViaAppLaunch(packageName)
        if (appStarted) markAppRelaunched(packageName)
        for (candidate in failed) {
            if (appStarted) {
                appendAuditEvent(packageName, candidate.serviceClass, candidate.label, "RESTART_SUCCESS", "AUTOMATIC", "restart method: app launch (grouped worker)")
                if (candidate.notifEnabled) {
                    sendNotification(candidate.appName, "Background services were stopped and the app was restarted.")
                }
            } else {
                appendAuditEvent(packageName, candidate.serviceClass, candidate.label, "RESTART_FAILED", "AUTOMATIC", "direct restart failed; grouped app restart also failed")
            }
        }
    }

    private fun monitoredCandidatesForPackage(packageName: String): List<WorkerCandidate> {
        return try {
            val prefs = applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val arr = JSONArray(prefs.getString(SERVICES_KEY, "[]"))
            (0 until arr.length()).mapNotNull { index ->
                val obj = arr.getJSONObject(index)
                if (!obj.optBoolean("enabled", true) ||
                    obj.optString("packageName") != packageName
                ) {
                    return@mapNotNull null
                }
                WorkerCandidate(
                    serviceClass = obj.getString("serviceClass"),
                    label = obj.optString("displayLabel", packageName),
                    appName = obj.optString("appName", obj.optString("displayLabel", packageName)),
                    appRestartEnabled = obj.optBoolean("appRestartEnabled", false),
                    notifEnabled = obj.optBoolean("notificationsEnabled", true)
                )
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun notificationsEnabledFor(pkg: String, cls: String): Boolean {
        return try {
            val prefs = applicationContext.getSharedPreferences(PREFS_NAME, android.content.Context.MODE_PRIVATE)
            val arr = org.json.JSONArray(prefs.getString(SERVICES_KEY, "[]"))
            for (i in 0 until arr.length()) {
                val obj = arr.getJSONObject(i)
                if (obj.getString("packageName") == pkg && obj.getString("serviceClass") == cls) {
                    return obj.optBoolean("notificationsEnabled", true)
                }
            }
            true
        } catch (_: Exception) { true }
    }

    private fun appendAuditEvent(
        pkg: String, cls: String, lbl: String,
        evt: String, trg: String, notes: String?
    ) {
        try {
            val prefs = applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val existing = prefs.getString(AUDIT_KEY, "[]")
            val arr = JSONArray(existing)
            val obj = JSONObject().apply {
                put("ts", java.time.Instant.now().toString())
                put("pkg", pkg)
                put("cls", cls)
                put("lbl", lbl)
                put("evt", evt)
                put("trg", trg)
                if (notes != null) put("notes", notes)
            }
            arr.put(obj)
            prefs.edit().putString(AUDIT_KEY, arr.toString()).apply()
        } catch (_: Exception) {}
    }

    private fun sendNotification(title: String, text: String) {
        val nm = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE)
            as NotificationManager

        val channel = NotificationChannel(
            CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_DEFAULT
        ).apply { description = "Service restart notifications" }
        nm.createNotificationChannel(channel)

        val tapIntent = android.app.PendingIntent.getActivity(
            applicationContext, notifId,
            android.content.Intent(applicationContext, MainActivity::class.java).apply {
                flags = android.content.Intent.FLAG_ACTIVITY_NEW_TASK or android.content.Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT
        )
        val notif = NotificationCompat.Builder(applicationContext, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_manage)
            .setContentTitle(title)
            .setContentText(text)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setContentIntent(tapIntent)
            .setAutoCancel(true)
            .setGroup(GROUP_KEY)
            .build()

        nm.notify(notifId++, notif)

        val summary = NotificationCompat.Builder(applicationContext, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_manage)
            .setContentTitle("Service Keeper")
            .setContentText("Service restarts")
            .setGroup(GROUP_KEY)
            .setGroupSummary(true)
            .setAutoCancel(true)
            .build()
        nm.notify(SUMMARY_ID, summary)
    }
}
