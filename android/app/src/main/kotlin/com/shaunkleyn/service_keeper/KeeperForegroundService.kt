package com.shaunkleyn.service_keeper

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.database.ContentObserver
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import java.util.Collections
import android.provider.Settings
import androidx.core.app.NotificationCompat
import org.json.JSONArray
import org.json.JSONObject
import rikka.shizuku.Shizuku
import java.io.BufferedReader
import java.io.InputStreamReader

class KeeperForegroundService : Service() {

    companion object {
        private const val CHANNEL_ID = "keeper_persistent"
        private const val RESTART_CHANNEL_ID = "service_keeper_restarts"
        private const val NOTIF_ID = 1
        private const val EXTRA_COUNT = "serviceCount"
        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val SERVICES_KEY = "flutter.monitored_services"
        private const val A11Y_KEY = "flutter.a11y_monitored"
        private const val NOTIF_LISTENER_KEY = "flutter.notif_monitored"
        private const val A11Y_NOTIF_OFF_KEY = "flutter.a11y_notif_off"
        private const val NOTIF_LISTENER_NOTIF_OFF_KEY = "flutter.notif_listener_notif_off"
        private const val AUDIT_KEY = "flutter.pending_audit_events"
        private const val RELAUNCH_POLL_INTERVAL_MS = 10_000L
        private var notifId = 2000

        fun start(context: Context, serviceCount: Int? = null) {
            val count = serviceCount ?: readCountFromPrefs(context)
            val intent = Intent(context, KeeperForegroundService::class.java)
                .putExtra(EXTRA_COUNT, count)
            KeeperRecovery.schedule(context.applicationContext)
            context.startForegroundService(intent)
        }

        fun stop(context: Context) {
            KeeperRecovery.cancel(context.applicationContext)
            context.stopService(Intent(context, KeeperForegroundService::class.java))
        }

        fun hasConfiguredServices(context: Context): Boolean = readCountFromPrefs(context) > 0

        private fun readCountFromPrefs(context: Context): Int {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val raw = prefs.getString(SERVICES_KEY, null) ?: return 0
            return try { JSONArray(raw).length() } catch (_: Exception) { 0 }
        }
    }

    private var currentCount = 0
    @Volatile private var logcatProcess: Process? = null
    private var logcatThread: Thread? = null
    private var a11yObserver: ContentObserver? = null
    private var notifObserver: ContentObserver? = null
    private var unlockReceiver: android.content.BroadcastReceiver? = null

    private data class RestartCandidate(
        val packageName: String,
        val serviceClass: String,
        val label: String,
        val notifEnabled: Boolean,
        val appRestartEnabled: Boolean
    )

    private val packageRestartLock = Any()
    private val pendingPackageRestarts = mutableMapOf<String, MutableMap<String, RestartCandidate>>()
    private val activePackageRestarts = mutableSetOf<String>()

    private val relaunchPollHandler = Handler(Looper.getMainLooper())
    private val relaunchPollRunnable: Runnable = object : Runnable {
        override fun run() {
            // pollPendingRelaunches() does its own cheap-check-then-maybe-spawn-thread.
            // No need to unconditionally spawn a thread every tick here too.
            pollPendingRelaunches()
            relaunchPollHandler.postDelayed(this, RELAUNCH_POLL_INTERVAL_MS)
        }
    }

    // Tracks packages currently being app-restarted to avoid duplicate launches
    private val appRestartingPackages: MutableSet<String> = Collections.synchronizedSet(mutableSetOf())

    // Debounced grouped notification for logcat-triggered service restarts
    private val pendingServiceNotifs: MutableList<String> = Collections.synchronizedList(mutableListOf())
    private val notifDebounceHandler = Handler(Looper.getMainLooper())
    private val flushServiceNotifs = Runnable {
        val items = synchronized(pendingServiceNotifs) {
            val copy = pendingServiceNotifs.toList()
            pendingServiceNotifs.clear()
            copy
        }
        if (items.isEmpty()) return@Runnable
        val distinct = items.distinct()
        if (items.size == 1) {
            sendNotification(distinct[0], "Background service was stopped and has been restarted.")
        } else if (distinct.size == 1) {
            sendNotification(distinct[0], "${items.size} background services were stopped and have been restarted.")
        } else {
            sendNotification("Service Keeper", "${items.size} background services restarted: ${distinct.joinToString(", ")}.")
        }
    }

    private val binderReceivedListener = Shizuku.OnBinderReceivedListener {
        startLogcatMonitor()
        checkAccessibilityServices()
        checkNotificationListeners()
    }

    override fun onCreate() {
        super.onCreate()
        Shizuku.addBinderReceivedListenerSticky(binderReceivedListener)
        startA11yObserver()
        startNotifObserver()
        startUnlockReceiver()
        relaunchPollHandler.postDelayed(relaunchPollRunnable, RELAUNCH_POLL_INTERVAL_MS)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        currentCount = intent?.getIntExtra(EXTRA_COUNT, currentCount) ?: currentCount
        ensureChannel()
        startForeground(NOTIF_ID, buildNotification())
        startLogcatMonitor()
        return START_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        Shizuku.removeBinderReceivedListener(binderReceivedListener)
        stopLogcatMonitor()
        stopA11yObserver()
        stopNotifObserver()
        stopUnlockReceiver()
        relaunchPollHandler.removeCallbacks(relaunchPollRunnable)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        // Recents-swipe is a stronger kill signal than plain process death: some OEMs
        // treat it as "user doesn't want this running" and skip the normal START_STICKY
        // restart. Don't wait for the 15-minute alarm - kick recovery immediately.
        KeeperRecoveryWorker.enqueue(applicationContext)
    }

    // ── Deferred relaunch on unlock ("locked" idle mode) ───────────────────────

    private fun startUnlockReceiver() {
        if (unlockReceiver != null) return
        val receiver = object : android.content.BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                // Only the "locked" mode treats unlock itself as the idle signal - for
                // other modes, unlocking means the user is now active, so let the
                // periodic poll re-evaluate isIdle() normally instead of draining blind.
                if (DeviceIdleChecker.getConfiguredMode(applicationContext) != "locked") return
                Thread { drainPendingRelaunches() }.start()
            }
        }
        unlockReceiver = receiver
        registerReceiver(receiver, android.content.IntentFilter(Intent.ACTION_USER_PRESENT))
    }

    private fun stopUnlockReceiver() {
        unlockReceiver?.let { unregisterReceiver(it) }
        unlockReceiver = null
    }

    private fun pollPendingRelaunches() {
        if (!PendingRelaunchQueue.hasPending(applicationContext)) return
        Thread {
            if (DeviceIdleChecker.isIdleFromPrefs(applicationContext)) drainPendingRelaunches()
        }.start()
    }

    private fun drainPendingRelaunches() {
        val pending = PendingRelaunchQueue.drainAll(applicationContext)
        for ((packageName, entries) in pending.groupBy { it.packageName }) {
            entries.forEach { entry ->
                appendAuditEvent(entry.packageName, entry.serviceClass, entry.label, "RESTART_ATTEMPTED", "AUTOMATIC", "deferred relaunch, device now idle")
            }
            val appStarted = restartApp(packageName)
            for (entry in entries) {
                if (appStarted) {
                    appendAuditEvent(entry.packageName, entry.serviceClass, entry.label, "RESTART_SUCCESS", "AUTOMATIC", "restart method: app launch (deferred, grouped)")
                    if (entry.notifEnabled) {
                        pendingServiceNotifs.add(getAppName(entry.packageName))
                    }
                } else {
                    appendAuditEvent(entry.packageName, entry.serviceClass, entry.label, "RESTART_FAILED", "AUTOMATIC", "deferred relaunch failed")
                }
            }
            if (appStarted && entries.any { it.notifEnabled }) {
                notifDebounceHandler.removeCallbacks(flushServiceNotifs)
                notifDebounceHandler.postDelayed(flushServiceNotifs, 1500)
            }
        }
    }

    // ── Accessibility service guardian ────────────────────────────────────────

    private fun startA11yObserver() {
        val uri = Settings.Secure.getUriFor("enabled_accessibility_services")
        a11yObserver = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) {
                checkAccessibilityServices()
            }
        }
        contentResolver.registerContentObserver(uri, false, a11yObserver!!)
    }

    private fun stopA11yObserver() {
        a11yObserver?.let { contentResolver.unregisterContentObserver(it) }
        a11yObserver = null
    }

    private fun checkAccessibilityServices() {
        if (!ShizukuExecutor.isReady()) return
        Thread {
            try {
                val current = ShizukuExecutor.exec(
                    "settings get secure enabled_accessibility_services"
                )?.trim()?.takeIf { it.isNotEmpty() && it != "null" } ?: return@Thread

                val enabledSet = current.split(":").mapNotNull { entry ->
                    val slash = entry.indexOf('/'); if (slash < 0) return@mapNotNull null
                    val p = entry.substring(0, slash)
                    var c = entry.substring(slash + 1)
                    if (c.startsWith(".")) c = p + c
                    "$p/$c"
                }.toSet()

                val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                val raw = prefs.getString(A11Y_KEY, null) ?: return@Thread
                val arr = JSONArray(raw)

                val notifOffRaw = prefs.getString(A11Y_NOTIF_OFF_KEY, "[]")
                val notifOffArr = JSONArray(notifOffRaw)
                val notifOffSet = (0 until notifOffArr.length()).map { notifOffArr.getString(it) }.toSet()

                var updated = current
                val a11yNotifApps = mutableListOf<String>()
                val uninstalledKeys = mutableListOf<String>()
                for (i in 0 until arr.length()) {
                    val key = arr.getString(i)
                    val slash = key.indexOf('/'); if (slash < 0) continue
                    val pkg = key.substring(0, slash)
                    val cls = key.substring(slash + 1)

                    if (!isPackageInstalled(pkg)) {
                        uninstalledKeys.add(key)
                        continue
                    }

                    if (enabledSet.contains("$pkg/$cls")) continue

                    val label = cls.substringAfterLast('.')
                    updated = "$updated:$pkg/$cls"
                    appendAuditEvent(pkg, cls, label, "DETECTED_STOPPED", "AUTOMATIC", "accessibility disabled by system")
                    appendAuditEvent(pkg, cls, label, "RESTART_ATTEMPTED", "AUTOMATIC", null)
                    appendAuditEvent(pkg, cls, label, "RESTART_SUCCESS", "AUTOMATIC", "re-added to enabled_accessibility_services")
                    if (!notifOffSet.contains("$pkg/$cls")) {
                        a11yNotifApps.add(getAppName(pkg))
                    }
                }

                if (updated != current) {
                    ShizukuExecutor.exec("settings put secure enabled_accessibility_services $updated")
                }

                if (uninstalledKeys.isNotEmpty()) {
                    val newArr = org.json.JSONArray()
                    for (i in 0 until arr.length()) {
                        val k = arr.getString(i)
                        if (!uninstalledKeys.contains(k)) newArr.put(k)
                    }
                    prefs.edit().putString(A11Y_KEY, newArr.toString()).apply()
                }

                val a11yDistinct = a11yNotifApps.distinct()
                when {
                    a11yNotifApps.size == 1 -> sendNotification(a11yDistinct[0], "Accessibility access was revoked and has been re-enabled.")
                    a11yNotifApps.size > 1 && a11yDistinct.size == 1 -> sendNotification(a11yDistinct[0], "${a11yNotifApps.size} accessibility services re-enabled.")
                    a11yNotifApps.size > 1 -> sendNotification("Service Keeper", "Accessibility access re-enabled for: ${a11yDistinct.joinToString(", ")}.")
                }
            } catch (_: Exception) {}
        }.start()
    }

    private fun getAppName(pkg: String): String {
        return try {
            val pm = applicationContext.packageManager
            pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
        } catch (_: Exception) { pkg }
    }

    private fun isPackageInstalled(pkg: String): Boolean {
        return try {
            applicationContext.packageManager.getApplicationInfo(pkg, 0)
            true
        } catch (_: Exception) { false }
    }

    private fun isAccessibilityService(pkg: String, cls: String): Boolean {
        return try {
            val pm = applicationContext.packageManager
            val pkgInfo = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                pm.getPackageInfo(pkg, android.content.pm.PackageManager.PackageInfoFlags.of(
                    android.content.pm.PackageManager.GET_SERVICES.toLong()
                ))
            } else {
                @Suppress("DEPRECATION")
                pm.getPackageInfo(pkg, android.content.pm.PackageManager.GET_SERVICES)
            }
            pkgInfo.services?.any {
                it.name == cls && it.permission == "android.permission.BIND_ACCESSIBILITY_SERVICE"
            } ?: false
        } catch (_: Exception) { false }
    }

    // ── Notification listener guardian ───────────────────────────────────────

    private fun startNotifObserver() {
        val uri = Settings.Secure.getUriFor("enabled_notification_listeners")
        notifObserver = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) {
                checkNotificationListeners()
            }
        }
        contentResolver.registerContentObserver(uri, false, notifObserver!!)
    }

    private fun stopNotifObserver() {
        notifObserver?.let { contentResolver.unregisterContentObserver(it) }
        notifObserver = null
    }

    private fun checkNotificationListeners() {
        if (!ShizukuExecutor.isReady()) return
        Thread {
            try {
                val current = ShizukuExecutor.exec(
                    "settings get secure enabled_notification_listeners"
                )?.trim()?.takeIf { it.isNotEmpty() && it != "null" } ?: return@Thread

                val enabledSet = current.split(":").mapNotNull { entry ->
                    val slash = entry.indexOf('/'); if (slash < 0) return@mapNotNull null
                    val p = entry.substring(0, slash)
                    var c = entry.substring(slash + 1)
                    if (c.startsWith(".")) c = p + c
                    "$p/$c"
                }.toSet()

                val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                val raw = prefs.getString(NOTIF_LISTENER_KEY, null) ?: return@Thread
                val arr = JSONArray(raw)

                val nlNotifOffRaw = prefs.getString(NOTIF_LISTENER_NOTIF_OFF_KEY, "[]")
                val nlNotifOffArr = JSONArray(nlNotifOffRaw)
                val nlNotifOffSet = (0 until nlNotifOffArr.length()).map { nlNotifOffArr.getString(it) }.toSet()

                var updated = current
                val notifListenerApps = mutableListOf<String>()
                val uninstalledKeys = mutableListOf<String>()
                for (i in 0 until arr.length()) {
                    val key = arr.getString(i)
                    val slash = key.indexOf('/'); if (slash < 0) continue
                    val pkg = key.substring(0, slash)
                    val cls = key.substring(slash + 1)

                    if (!isPackageInstalled(pkg)) {
                        uninstalledKeys.add(key)
                        continue
                    }

                    if (enabledSet.contains("$pkg/$cls")) continue

                    val label = cls.substringAfterLast('.')
                    updated = "$updated:$pkg/$cls"
                    appendAuditEvent(pkg, cls, label, "DETECTED_STOPPED", "AUTOMATIC", "notification listener disabled by system")
                    appendAuditEvent(pkg, cls, label, "RESTART_ATTEMPTED", "AUTOMATIC", null)
                    appendAuditEvent(pkg, cls, label, "RESTART_SUCCESS", "AUTOMATIC", "re-added to enabled_notification_listeners")
                    if (!nlNotifOffSet.contains("$pkg/$cls")) {
                        notifListenerApps.add(getAppName(pkg))
                    }
                }

                if (updated != current) {
                    ShizukuExecutor.exec("settings put secure enabled_notification_listeners $updated")
                }

                if (uninstalledKeys.isNotEmpty()) {
                    val newArr = org.json.JSONArray()
                    for (i in 0 until arr.length()) {
                        val k = arr.getString(i)
                        if (!uninstalledKeys.contains(k)) newArr.put(k)
                    }
                    prefs.edit().putString(NOTIF_LISTENER_KEY, newArr.toString()).apply()
                }

                val nlDistinct = notifListenerApps.distinct()
                when {
                    notifListenerApps.size == 1 -> sendNotification(nlDistinct[0], "Notification access was revoked and has been re-enabled.")
                    notifListenerApps.size > 1 && nlDistinct.size == 1 -> sendNotification(nlDistinct[0], "${notifListenerApps.size} notification listeners re-enabled.")
                    notifListenerApps.size > 1 -> sendNotification("Service Keeper", "Notification access re-enabled for: ${nlDistinct.joinToString(", ")}.")
                }
            } catch (_: Exception) {}
        }.start()
    }

    private fun isNotificationListener(pkg: String, cls: String): Boolean {
        return try {
            val pm = applicationContext.packageManager
            val pkgInfo = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                pm.getPackageInfo(pkg, android.content.pm.PackageManager.PackageInfoFlags.of(
                    android.content.pm.PackageManager.GET_SERVICES.toLong()
                ))
            } else {
                @Suppress("DEPRECATION")
                pm.getPackageInfo(pkg, android.content.pm.PackageManager.GET_SERVICES)
            }
            pkgInfo.services?.any {
                it.name == cls && it.permission == "android.permission.BIND_NOTIFICATION_LISTENER_SERVICE"
            } ?: false
        } catch (_: Exception) { false }
    }

    // ── Logcat service monitor ────────────────────────────────────────────────

    @Synchronized
    private fun startLogcatMonitor() {
        if (logcatThread?.isAlive == true) return
        if (!ShizukuExecutor.isReady()) return

        logcatThread = Thread { runLogcatLoop() }.also {
            it.isDaemon = true
            it.start()
        }
    }

    @Synchronized
    private fun stopLogcatMonitor() {
        logcatThread?.interrupt()
        logcatProcess?.destroy()
        logcatThread = null
        logcatProcess = null
    }

    private fun runLogcatLoop() {
        while (!Thread.currentThread().isInterrupted) {
            try {
                val process = ShizukuHelper.newProcess(
                    arrayOf("logcat", "-s", "ActivityManager:I", "-v", "brief"),
                    null,
                    "/"
                )
                logcatProcess = process
                val reader = BufferedReader(InputStreamReader(process.inputStream))
                var line: String?
                while (reader.readLine().also { line = it } != null) {
                    if (Thread.currentThread().isInterrupted) return
                    line?.let { handleLogLine(it) }
                }
            } catch (_: InterruptedException) {
                return
            } catch (_: Exception) {}

            // Process exited or failed — wait before retrying
            try {
                Thread.sleep(10_000)
            } catch (_: InterruptedException) {
                return
            }
        }
    }

    // Matches both "Force stopping service" (am force-stop) and "Stopping service:" (graceful/crash)
    private val serviceStopRe = Regex(
        """(?:Force stopping service|Stopping service:?)\s+ServiceRecord\{[^}]* u\d+ ([^\s/}]+)/([^\s}]+)""",
        RegexOption.IGNORE_CASE
    )

    // Matches process death (OOM kill, crash) — catches services not individually logged
    private val processDeathRe = Regex(
        """Process ([^\s(]+) \(pid \d+\) has died""",
        RegexOption.IGNORE_CASE
    )

    private fun handleLogLine(line: String) {
        when {
            line.contains("stopping service", ignoreCase = true) -> {
                val match = serviceStopRe.find(line) ?: return
                val pkg = match.groupValues[1]
                var cls = match.groupValues[2]
                if (cls.startsWith(".")) cls = pkg + cls
                triggerRestartForService(pkg, cls)
            }
            line.contains("has died", ignoreCase = true) -> {
                val match = processDeathRe.find(line) ?: return
                triggerRestartForPackage(match.groupValues[1])
            }
        }
    }

    private fun triggerRestartForService(pkg: String, cls: String) {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val raw = prefs.getString(SERVICES_KEY, null) ?: return
        try {
            val arr = JSONArray(raw)
            for (i in 0 until arr.length()) {
                val obj = arr.getJSONObject(i)
                if (!obj.optBoolean("enabled", true)) continue
                if (obj.getString("packageName") != pkg || obj.getString("serviceClass") != cls) continue
                val label = obj.optString("displayLabel", pkg)
                val notifEnabled = obj.optBoolean("notificationsEnabled", true)
                val appRestartEnabled = obj.optBoolean("appRestartEnabled", false)
                enqueueServiceRestart(
                    RestartCandidate(pkg, cls, label, notifEnabled, appRestartEnabled)
                )
                break
            }
        } catch (_: Exception) {}
    }

    private fun triggerRestartForPackage(pkg: String) {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val raw = prefs.getString(SERVICES_KEY, null) ?: return
        try {
            val arr = JSONArray(raw)
            for (i in 0 until arr.length()) {
                val obj = arr.getJSONObject(i)
                if (!obj.optBoolean("enabled", true)) continue
                if (obj.getString("packageName") != pkg) continue
                val cls = obj.getString("serviceClass")
                val label = obj.optString("displayLabel", pkg)
                val notifEnabled = obj.optBoolean("notificationsEnabled", true)
                val appRestartEnabled = obj.optBoolean("appRestartEnabled", false)
                enqueueServiceRestart(
                    RestartCandidate(pkg, cls, label, notifEnabled, appRestartEnabled)
                )
            }
        } catch (_: Exception) {}
    }

    private fun enqueueServiceRestart(candidate: RestartCandidate) {
        val shouldStartWorker = synchronized(packageRestartLock) {
            pendingPackageRestarts
                .getOrPut(candidate.packageName) { mutableMapOf() }[candidate.serviceClass] = candidate
            activePackageRestarts.add(candidate.packageName)
        }
        if (shouldStartWorker) {
            Thread { processPackageRestarts(candidate.packageName) }.start()
        }
    }

    private fun processPackageRestarts(pkg: String) {
        try {
            // Coalesce the individual service-stop lines emitted for one process death.
            Thread.sleep(500)
            val failedCandidates = mutableMapOf<String, RestartCandidate>()
            val allowAppRestartNow = DeviceIdleChecker.isIdleFromPrefs(applicationContext)
            while (true) {
                val batch = synchronized(packageRestartLock) {
                    pendingPackageRestarts.remove(pkg)?.values?.toList().orEmpty()
                }
                if (batch.isEmpty()) break

                for (candidate in batch) {
                    if (ShizukuExecutor.isServiceRunning(pkg, candidate.serviceClass)) continue

                    appendAuditEvent(pkg, candidate.serviceClass, candidate.label, "DETECTED_STOPPED", "AUTOMATIC", "logcat")
                    appendAuditEvent(pkg, candidate.serviceClass, candidate.label, "RESTART_ATTEMPTED", "AUTOMATIC", null)

                    val result = ShizukuExecutor.startServiceDetailed(
                        pkg,
                        candidate.serviceClass,
                        appRestartEnabled = false
                    )
                    if (result.ok) {
                        appendAuditEvent(pkg, candidate.serviceClass, candidate.label, "RESTART_SUCCESS", "AUTOMATIC", result.detail)
                        notifyServiceRestarted(candidate)
                    } else if (candidate.appRestartEnabled) {
                        failedCandidates[candidate.serviceClass] = candidate
                    } else {
                        appendAuditEvent(pkg, candidate.serviceClass, candidate.label, "RESTART_FAILED", "AUTOMATIC", result.detail)
                    }
                }

                // Pick up any stop events logged while the direct attempts were running.
                Thread.sleep(500)
            }

            if (failedCandidates.isEmpty()) return

            if (allowAppRestartNow) {
                val appStarted = restartApp(pkg)
                for (candidate in failedCandidates.values) {
                    if (appStarted) {
                        appendAuditEvent(pkg, candidate.serviceClass, candidate.label, "RESTART_SUCCESS", "AUTOMATIC", "restart method: app launch (grouped)")
                        notifyServiceRestarted(candidate)
                    } else {
                        appendAuditEvent(pkg, candidate.serviceClass, candidate.label, "RESTART_FAILED", "AUTOMATIC", "service start failed; app restart also failed")
                    }
                }
            } else {
                for (candidate in failedCandidates.values) {
                    PendingRelaunchQueue.enqueue(
                        applicationContext,
                        PendingRelaunchQueue.Entry(
                            pkg,
                            candidate.serviceClass,
                            candidate.label,
                            candidate.notifEnabled
                        )
                    )
                }
            }
        } catch (_: Exception) {}
        finally {
            val restartWorker = synchronized(packageRestartLock) {
                activePackageRestarts.remove(pkg)
                pendingPackageRestarts[pkg]?.isNotEmpty() == true && activePackageRestarts.add(pkg)
            }
            if (restartWorker) {
                Thread { processPackageRestarts(pkg) }.start()
            }
        }
    }

    private fun notifyServiceRestarted(candidate: RestartCandidate) {
        if (!candidate.notifEnabled) return
        pendingServiceNotifs.add(getAppName(candidate.packageName))
        notifDebounceHandler.removeCallbacks(flushServiceNotifs)
        notifDebounceHandler.postDelayed(flushServiceNotifs, 1500)
    }

    private fun restartApp(pkg: String): Boolean {
        if (!appRestartingPackages.add(pkg)) return false // already restarting this package
        return try {
            val launchIntent = applicationContext.packageManager.getLaunchIntentForPackage(pkg)
                ?: return false
            val component = launchIntent.component ?: return false
            val targetComponent = "${component.packageName}/${component.className}"
            val previousForeground = ShizukuExecutor.getForegroundApp()
            ShizukuExecutor.launchAndRestore(targetComponent, previousForeground)
        } finally {
            appRestartingPackages.remove(pkg)
        }
    }

    private fun appendAuditEvent(pkg: String, cls: String, lbl: String, evt: String, trg: String, notes: String?) {
        try {
            val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val arr = JSONArray(prefs.getString(AUDIT_KEY, "[]"))
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
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            RESTART_CHANNEL_ID, "Service Restarts", NotificationManager.IMPORTANCE_DEFAULT
        ).apply { description = "Service restart notifications" }
        nm.createNotificationChannel(channel)

        val tapIntent = PendingIntent.getActivity(
            this, notifId,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val notif = NotificationCompat.Builder(this, RESTART_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_manage)
            .setContentTitle(title)
            .setContentText(text)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setContentIntent(tapIntent)
            .setAutoCancel(true)
            .build()

        nm.notify(notifId++, notif)
    }

    private fun ensureChannel() {
        val nm = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID, "Service Keeper", NotificationManager.IMPORTANCE_LOW
        ).apply { description = "Service Keeper is actively monitoring background services" }
        nm.createNotificationChannel(channel)
    }

    private fun buildNotification() = run {
        val tapIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val text = if (currentCount == 0) "No services configured"
                   else "Monitoring $currentCount service${if (currentCount == 1) "" else "s"}"
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_manage)
            .setContentTitle("Service Keeper")
            .setContentText(text)
            .setContentIntent(tapIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }
}
