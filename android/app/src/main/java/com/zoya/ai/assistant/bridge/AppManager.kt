package com.zoya.ai.assistant.bridge

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import com.zoya.ai.assistant.accessibility.ZoyaAccessibilityService
import org.json.JSONArray
import org.json.JSONObject

class AppManager(private val context: Context) {

    private val pm: PackageManager get() = context.packageManager

    fun getInstalledApps(query: String? = null): BridgeResult {
        return try {
            val apps = pm.getInstalledApplications(PackageManager.GET_META_DATA)
            val arr = JSONArray()
            apps.filter { (it.flags and ApplicationInfo.FLAG_SYSTEM) == 0 || pm.getLaunchIntentForPackage(it.packageName) != null }
                .forEach { app ->
                    val label = pm.getApplicationLabel(app).toString()
                    if (query.isNullOrBlank() || label.contains(query, ignoreCase = true) ||
                        app.packageName.contains(query, ignoreCase = true)
                    ) {
                        arr.put(JSONObject().apply {
                            put("packageName", app.packageName)
                            put("label", label)
                            put("launchable", pm.getLaunchIntentForPackage(app.packageName) != null)
                        })
                    }
                }
            BridgeResult.success("Found ${arr.length()} app(s)", JSONObject().put("apps", arr))
        } catch (e: Exception) {
            BridgeResult.failure("Could not list installed apps: ${e.message}")
        }
    }

    fun launchApp(packageName: String): BridgeResult {
        val intent = pm.getLaunchIntentForPackage(packageName)
            ?: return BridgeResult.failure("App '$packageName' is not installed or has no launcher activity")
        return try {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            BridgeResult.success("Launched $packageName")
        } catch (e: Exception) {
            BridgeResult.failure("Failed to launch $packageName: ${e.message}")
        }
    }

    /** Best-effort: Android does not expose a general "current foreground app" API without
     * Accessibility or UsageStats. We use the accessibility service's last observed package. */
    fun getCurrentApp(): BridgeResult {
        val pkg = ZoyaAccessibilityService.instance?.lastEventPackage
            ?: return BridgeResult.permissionRequired("ACCESSIBILITY_SERVICE")
        return BridgeResult.success("Current app", JSONObject().put("packageName", pkg))
    }

    fun openAppInfo(packageName: String): BridgeResult {
        return try {
            val intent = Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = android.net.Uri.parse("package:$packageName")
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            context.startActivity(intent)
            BridgeResult.success("Opened app info for $packageName")
        } catch (e: Exception) {
            BridgeResult.failure("Could not open app info: ${e.message}")
        }
    }
}

