package com.aikobox.app.service

import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.util.Log

/**
 * The installed-package list behind the split-tunnelling picker.
 *
 * Shape is fixed by the channel contract: `{packageName, label, isSystem}`, which
 * `InstalledApp.fromJson` on the Dart side parses directly.
 *
 * **Package visibility caveat.** On Android 11 and later an app sees only itself, whatever
 * its `<queries>` block names, and — with `QUERY_ALL_PACKAGES` — everything. This app does
 * not hold `QUERY_ALL_PACKAGES`, so on API 30+ this returns a short list rather than the
 * device's real inventory. That is a manifest change, not a code change; until it lands the
 * picker is honest about what it can see rather than silently showing a truncated list as if
 * it were complete.
 */
object InstalledAppsReader {

    private const val TAG = "AikoInstalledApps"

    fun read(context: Context): List<Map<String, Any>> {
        val manager = context.packageManager
        val applications = try {
            manager.getInstalledApplications(PackageManager.GET_META_DATA)
        } catch (e: Exception) {
            Log.e(TAG, "cannot enumerate installed applications", e)
            return emptyList()
        }

        return applications
            .asSequence()
            .filter { it.packageName != context.packageName }
            // An app with no launcher entry and no INTERNET permission cannot originate
            // traffic, so listing it in a traffic-routing picker is noise.
            .filter { canUseNetwork(manager, it.packageName) }
            .map { info ->
                mapOf<String, Any>(
                    "packageName" to info.packageName,
                    "label" to labelOf(manager, info),
                    "isSystem" to ((info.flags and ApplicationInfo.FLAG_SYSTEM) != 0),
                )
            }
            .sortedWith(
                compareBy(
                    { it["isSystem"] as Boolean },
                    { (it["label"] as String).lowercase() },
                ),
            )
            .toList()
    }

    private fun labelOf(manager: PackageManager, info: ApplicationInfo): String =
        runCatching { manager.getApplicationLabel(info).toString() }
            .getOrNull()
            ?.takeIf { it.isNotBlank() }
            ?: info.packageName

    private fun canUseNetwork(manager: PackageManager, packageName: String): Boolean =
        manager.checkPermission(android.Manifest.permission.INTERNET, packageName) ==
            PackageManager.PERMISSION_GRANTED
}
