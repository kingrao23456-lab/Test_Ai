package com.zoya.ai.assistant.accessibility

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

/**
 * Persistent AccessibilityService required for all semantic UI automation.
 * This service purposefully does NOT read or exfiltrate anything by itself — it only exposes
 * read/interaction capabilities that ZoyaBridgePlugin calls on the user's explicit request.
 */
class ZoyaAccessibilityService : AccessibilityService() {

    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    lateinit var gestures: GestureExecutor
        private set

    var lastEventPackage: String? = null
        private set

    override fun onServiceConnected() {
        super.onServiceConnected()
        gestures = GestureExecutor(this)
        instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Event-driven, not polling — we just track the current foreground package here.
        // Heavier work (OCR, workflow condition checks) is triggered on-demand by the engine,
        // never continuously, per the PRD's performance requirements.
        event?.packageName?.let { lastEventPackage = it.toString() }
    }

    override fun onInterrupt() {
        // Required override; nothing to clean up here specifically.
    }

    override fun onDestroy() {
        super.onDestroy()
        if (instance == this) instance = null
    }

    fun currentRoot(): AccessibilityNodeInfo? = rootInActiveWindow

    fun performClick(node: AccessibilityNodeInfo): Boolean {
        return if (node.isClickable) {
            node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
        } else {
            // Walk up to the nearest clickable ancestor before giving up.
            var parent = node.parent
            var clicked = false
            while (parent != null) {
                if (parent.isClickable) {
                    clicked = parent.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                    break
                }
                parent = parent.parent
            }
            clicked
        }
    }

    fun performSetText(node: AccessibilityNodeInfo, text: String): Boolean {
        if (!node.isEditable) return false
        val args = android.os.Bundle()
        args.putCharSequence(
            AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text
        )
        return node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
    }

    fun performScroll(node: AccessibilityNodeInfo, forward: Boolean): Boolean {
        val action = if (forward) AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
        else AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
        return node.performAction(action)
    }

    fun globalBack(): Boolean = performGlobalAction(GLOBAL_ACTION_BACK)
    fun globalHome(): Boolean = performGlobalAction(GLOBAL_ACTION_HOME)
    fun globalRecents(): Boolean = performGlobalAction(GLOBAL_ACTION_RECENTS)

    companion object {
        /** Null when the user hasn't enabled the service in Android Settings. */
        var instance: ZoyaAccessibilityService? = null
            private set

        fun isEnabled(): Boolean = instance != null
    }
}
