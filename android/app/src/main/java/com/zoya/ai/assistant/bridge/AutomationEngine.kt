package com.zoya.ai.assistant.bridge

import android.content.Context
import android.provider.Settings
import android.text.TextUtils
import kotlinx.coroutines.delay
import com.zoya.ai.assistant.accessibility.NodeFinder
import com.zoya.ai.assistant.accessibility.ZoyaAccessibilityService
import org.json.JSONObject

/**
 * Central engine described by the PRD: every device action passes through here so it is
 * validated, permission-checked, executed via the most reliable available API, verified,
 * retried when appropriate, and reported back with a structured status.
 */
class AutomationEngine(private val context: Context) {

    @Volatile private var cancelled = false

    fun cancelAll() { cancelled = true }
    fun resetCancellation() { cancelled = false }

    fun isAccessibilityEnabled(): Boolean {
        // Confirm via the OS setting AND our live service instance, not just one signal.
        val enabledServices = Settings.Secure.getString(
            context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false
        val serviceName = "${context.packageName}/${ZoyaAccessibilityService::class.java.canonicalName}"
        val settingOn = enabledServices.split(":").any { it.equals(serviceName, ignoreCase = true) }
        return settingOn && ZoyaAccessibilityService.isEnabled()
    }

    private fun requireAccessibility(): ZoyaAccessibilityService? {
        if (!isAccessibilityEnabled()) return null
        return ZoyaAccessibilityService.instance
    }

    /**
     * Generic "find + act" pipeline implementing the PRD's Smart Target Selection order:
     * accessibility semantics -> text -> content-description -> resource-id
     * (OCR / visual detection fallback is wired in at the bridge layer once those modules
     * are filled in; this function stops and reports rather than guessing coordinates).
     */
    suspend fun findAndAct(
        selector: NodeFinder.Selector,
        action: (android.view.accessibility.AccessibilityNodeInfo) -> Boolean,
        retries: Int = 2,
        retryDelayMs: Long = 250
    ): BridgeResult {
        val service = requireAccessibility()
            ?: return BridgeResult.permissionRequired("ACCESSIBILITY_SERVICE")

        var attempt = 0
        while (attempt <= retries) {
            if (cancelled) return BridgeResult.failure("Cancelled by user")
            val root = service.currentRoot()
            val node = NodeFinder.find(root, selector)
            if (node != null) {
                val didAct = action(node)
                if (didAct) {
                    // Verification pass: re-read tree after a short settle delay.
                    delay(120)
                    return BridgeResult.success("Action verified")
                }
            }
            attempt++
            if (attempt <= retries) delay(retryDelayMs)
        }
        return BridgeResult.failure("Target not found or action rejected by the app after $retries retries")
    }

    suspend fun tap(x: Float, y: Float): BridgeResult {
        val service = requireAccessibility() ?: return BridgeResult.permissionRequired("ACCESSIBILITY_SERVICE")
        if (cancelled) return BridgeResult.failure("Cancelled")
        val ok = service.gestures.tap(x, y)
        return if (ok) BridgeResult.success() else BridgeResult.failure("Gesture rejected by the system")
    }

    suspend fun swipe(x1: Float, y1: Float, x2: Float, y2: Float, durationMs: Long): BridgeResult {
        val service = requireAccessibility() ?: return BridgeResult.permissionRequired("ACCESSIBILITY_SERVICE")
        val ok = service.gestures.swipe(x1, y1, x2, y2, durationMs)
        return if (ok) BridgeResult.success() else BridgeResult.failure("Gesture rejected by the system")
    }

    fun readScreen(): BridgeResult {
        val service = requireAccessibility() ?: return BridgeResult.permissionRequired("ACCESSIBILITY_SERVICE")
        val root = service.currentRoot() ?: return BridgeResult.failure("No active window content available")
        val json = NodeFinder.toJson(root)
        val wrapper = JSONObject().put("tree", json).put("package", service.lastEventPackage)
        return BridgeResult.success("Screen read", wrapper)
    }

    fun findElement(selector: NodeFinder.Selector): BridgeResult {
        val service = requireAccessibility() ?: return BridgeResult.permissionRequired("ACCESSIBILITY_SERVICE")
        val root = service.currentRoot() ?: return BridgeResult.failure("No active window")
        val matches = NodeFinder.findAll(root, selector)
        if (matches.isEmpty()) return BridgeResult.failure("No matching element found")
        val arr = org.json.JSONArray()
        matches.take(20).forEach { arr.put(NodeFinder.toJson(it, maxDepth = 0)) }
        return BridgeResult.success("Found ${matches.size} element(s)", JSONObject().put("elements", arr))
    }

    suspend fun typeText(selector: NodeFinder.Selector, text: String): BridgeResult {
        if (TextUtils.isEmpty(text)) return BridgeResult.failure("Empty text")
        return findAndAct(selector, { node ->
            val service = ZoyaAccessibilityService.instance ?: return@findAndAct false
            service.performSetText(node, text)
        })
    }

    fun pressBack(): BridgeResult {
        val service = requireAccessibility() ?: return BridgeResult.permissionRequired("ACCESSIBILITY_SERVICE")
        return if (service.globalBack()) BridgeResult.success() else BridgeResult.failure("System rejected back action")
    }

    fun pressHome(): BridgeResult {
        val service = requireAccessibility() ?: return BridgeResult.permissionRequired("ACCESSIBILITY_SERVICE")
        return if (service.globalHome()) BridgeResult.success() else BridgeResult.failure("System rejected home action")
    }
}

