package com.shaunkleyn.service_keeper

import rikka.shizuku.Shizuku
import java.io.BufferedReader
import java.io.InputStreamReader

object ShizukuExecutor {

    data class StartResult(val ok: Boolean, val detail: String?)

    private val broadcastStartActionCache = mutableMapOf<String, List<String>>()

    fun isReady(): Boolean = try {
        Shizuku.pingBinder() && Shizuku.checkSelfPermission() == android.content.pm.PackageManager.PERMISSION_GRANTED
    } catch (e: Exception) {
        false
    }

    fun exec(command: String): String? {
        if (!isReady()) return null
        return try {
            val process = ShizukuHelper.newProcess(
                arrayOf("sh", "-c", "$command 2>&1"),
                null,
                "/"
            )
            val reader = BufferedReader(InputStreamReader(process.inputStream))
            val output = StringBuilder()
            var line: String?
            while (reader.readLine().also { line = it } != null) {
                output.appendLine(line)
            }
            process.waitFor()
            output.toString()
        } catch (e: Exception) {
            null
        }
    }

    fun isServiceRunning(packageName: String, serviceClass: String): Boolean {
        val output = exec("dumpsys activity services $packageName") ?: return false
        return parseDumpsysServices(output).any { (pkg, cls) ->
            pkg == packageName && cls == serviceClass
        }
    }

    private fun parseDumpsysServices(output: String): List<Pair<String, String>> {
        val re = Regex(
            """ServiceRecord\{(?:0x)?[0-9a-f]+ +u\d+ +([^\s/}]+)/([^\s}]+)""",
            RegexOption.IGNORE_CASE
        )
        return re.findAll(output).map { match ->
            val pkg = match.groupValues[1]
            var cls = match.groupValues[2]
            if (cls.startsWith(".")) cls = pkg + cls
            Pair(pkg, cls)
        }.toList()
    }

    fun startServiceDetailed(
        packageName: String,
        serviceClass: String,
        appRestartEnabled: Boolean = false,
        allowAppRestartNow: Boolean = true
    ): StartResult {
        val component = "$packageName/$serviceClass"
        val result = exec("am start-foreground-service -n $component")
        if (result == null || result.contains("Error", ignoreCase = true)) {
            // Fallback for older APIs or non-foreground services
            val fallback = exec("am startservice -n $component")
            if (fallback != null && !fallback.contains("Error", ignoreCase = true)) {
                return StartResult(true, "restart method: direct startservice")
            }

            var appRestartSkipped = false
            if (appRestartEnabled) {
                if (allowAppRestartNow) {
                    val launched = restartViaAppLaunch(packageName)
                    // Keep behavior consistent with manual restart path in Dart.
                    // App launch fallback is considered a successful recovery trigger
                    // even when service visibility in dumpsys is delayed.
                    if (launched) {
                        return StartResult(true, "restart method: app launch")
                    }
                } else {
                    appRestartSkipped = true
                }
            }

            val broadcast = tryBroadcastStartFallback(packageName, serviceClass)
            if (broadcast.ok) return broadcast

            // Accessibility services cannot be started via am, toggle the settings key instead.
            val a11y = tryAccessibilityToggle(packageName, serviceClass)
            if (a11y.ok) return a11y

            val reason = if (fallback == null) {
                parseAmError(result) ?: "Shizuku returned null"
            } else {
                parseAmError(fallback) ?: fallback.trim()
            }
            val parts = listOfNotNull(
                "app relaunch skipped: device in active use".takeIf { appRestartSkipped },
                broadcast.detail?.takeIf { it.isNotBlank() }?.let { "broadcast fallback failed: $it" },
                a11y.detail?.takeIf { it.isNotBlank() }
            )
            val detail = if (parts.isEmpty()) reason else "$reason; ${parts.joinToString("; ")}"
            return StartResult(false, detail)
        }
        return StartResult(true, "restart method: direct start-foreground-service")
    }

    /** Returns (packageName, className) of the currently foregrounded activity, or null. */
    fun getForegroundApp(): Pair<String, String>? {
        val output = exec("dumpsys activity activities") ?: return null
        val re = Regex(
            """ResumedActivity: ActivityRecord\{(?:0x)?[0-9a-f]+ +u\d+ +([^\s/]+)/([^\s}]+)""",
            RegexOption.IGNORE_CASE
        )
        val match = re.find(output) ?: return null
        val pkg = match.groupValues[1]
        var cls = match.groupValues[2]
        if (cls.startsWith(".")) cls = pkg + cls
        return Pair(pkg, cls)
    }

    private fun isErrorOutput(output: String?): Boolean =
        output == null || output.contains("error", ignoreCase = true)

    /**
     * Starts [targetComponent], waits for it to settle, then returns to whatever was
     * in the foreground before ([previousForeground], from [getForegroundApp]) - or
     * HOME if there was nothing to restore or restoring it failed. Shared by every
     * app-relaunch fallback path (Dart's manual restart mirrors this same sequence).
     */
    fun launchAndRestore(targetComponent: String, previousForeground: Pair<String, String>?): Boolean {
        val result = exec("am start -n $targetComponent")
        if (isErrorOutput(result)) return false
        android.os.SystemClock.sleep(1200)

        val previousComponent = previousForeground?.let { "${it.first}/${it.second}" }
        if (previousComponent != null && previousComponent != targetComponent) {
            val restore = exec("am start -n $previousComponent")
            if (isErrorOutput(restore)) {
                exec("input keyevent 3") // fall back to HOME if restore failed
            }
        } else {
            exec("input keyevent 3") // no prior app known, or it was already the target
        }
        return true
    }

    fun restartViaAppLaunch(packageName: String): Boolean {
        val previousForeground = getForegroundApp()

        val resolved = exec(
            "cmd package resolve-activity --brief " +
                "-a android.intent.action.MAIN " +
                "-c android.intent.category.LAUNCHER $packageName"
        )
        val component = resolved
            ?.lineSequence()
            ?.map { it.trim() }
            ?.lastOrNull { it.contains('/') } ?: return false

        return launchAndRestore(component, previousForeground)
    }

    private fun tryAccessibilityToggle(packageName: String, serviceClass: String): StartResult {
        val current = exec("settings get secure enabled_accessibility_services")?.trim()
            ?: return StartResult(false, null)
        if (current == "null" || current.isEmpty()) return StartResult(false, null)

        val entries = current.split(":")
        val target = "$packageName/$serviceClass"
        // Entries may use short-form (pkg/.Class); expand before comparing
        val found = entries.firstOrNull { entry ->
            val slash = entry.indexOf('/')
            if (slash < 0) return@firstOrNull false
            val pkg = entry.substring(0, slash)
            var cls = entry.substring(slash + 1)
            if (cls.startsWith(".")) cls = pkg + cls
            "$pkg/$cls" == target
        } ?: return StartResult(false, null) // not an accessibility service

        // Disable: remove from settings list
        val without = entries.filter { it != found }
        if (without.isEmpty()) {
            exec("settings delete secure enabled_accessibility_services")
        } else {
            exec("settings put secure enabled_accessibility_services ${without.joinToString(":")}")
        }
        Thread.sleep(1000)

        // Re-enable: add back in original format (preserves short-form if that's how it was stored)
        val afterDisable = exec("settings get secure enabled_accessibility_services")?.trim()
        val restored = if (afterDisable == null || afterDisable == "null" || afterDisable.isEmpty()) {
            found
        } else {
            "$afterDisable:$found"
        }
        exec("settings put secure enabled_accessibility_services $restored")
        Thread.sleep(2000)

        return if (isServiceRunning(packageName, serviceClass)) {
            StartResult(true, "restart method: accessibility toggle")
        } else {
            StartResult(false, "accessibility toggle attempted but service not detected running")
        }
    }

    fun startService(packageName: String, serviceClass: String, appRestartEnabled: Boolean = false): Boolean {
        return startServiceDetailed(packageName, serviceClass, appRestartEnabled).ok
    }

    private fun tryBroadcastStartFallback(packageName: String, serviceClass: String): StartResult {
        val actions = getBroadcastStartActions(packageName)
        if (actions.isEmpty()) {
            return StartResult(false, "no matching exported start/toggle broadcast actions found")
        }

        val tried = mutableListOf<String>()
        for (action in actions) {
            tried += action
            exec(
                "am broadcast --user 0 --include-stopped-packages " +
                    "-a $action -p $packageName"
            )

            Thread.sleep(2000)
            if (isServiceRunning(packageName, serviceClass)) {
                return StartResult(true, "restart method: broadcast fallback ($action)")
            }
        }

        return StartResult(false, "tried actions: ${tried.joinToString(", ")}")
    }

    private fun getBroadcastStartActions(packageName: String): List<String> {
        broadcastStartActionCache[packageName]?.let { return it }

        val discovered = mutableListOf<String>()
        val output = exec("dumpsys package $packageName")
        if (!output.isNullOrBlank()) {
            val re = Regex("Action: \"([^\"]+)\"")
            for (match in re.findAll(output)) {
                val action = match.groupValues.getOrNull(1) ?: continue
                val upper = action.uppercase()
                if (!upper.startsWith("${packageName.uppercase()}.")) continue
                if (upper.contains("START") || upper.contains("TOGGLE") || upper.contains("RESTART")) {
                    discovered += action
                }
            }
        }

        val guesses = listOf(
            "$packageName.INTENT_START_SERVICE",
            "$packageName.INTENT_RESTART_SERVICE",
            "$packageName.INTENT_TOGGLE_SERVICE",
            "$packageName.ACTION_START_SERVICE",
            "$packageName.ACTION_RESTART_SERVICE",
            "$packageName.ACTION_TOGGLE_SERVICE",
        )

        val deduped = linkedSetOf<String>()
        deduped.addAll(discovered)
        deduped.addAll(guesses)

        val result = deduped.toList()
        broadcastStartActionCache[packageName] = result
        return result
    }

    private fun parseAmError(output: String?): String? {
        if (output.isNullOrBlank()) return null
        val line = output.lineSequence().firstOrNull { it.trimStart().startsWith("Error:") }
            ?: return output.trim().ifBlank { null }
        return line.substringAfter("Error:", line).trim().ifBlank { null }
    }
}
