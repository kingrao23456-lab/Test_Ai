package com.zoya.ai.assistant.accessibility

import android.graphics.Rect
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONArray
import org.json.JSONObject

/**
 * Implements "Smart Target Selection" from the PRD:
 * accessibility semantics -> text match -> content-desc -> resource-id -> (OCR/visual happen
 * outside this class, in the bridge/engine layer, as they don't need the accessibility tree).
 */
object NodeFinder {

    data class Selector(
        val text: String? = null,
        val partialText: String? = null,
        val regex: Regex? = null,
        val contentDescription: String? = null,
        val resourceId: String? = null,
        val className: String? = null
    )

    /** Walks the whole visible tree once and returns every node (used for "read screen"). */
    fun collectAll(root: AccessibilityNodeInfo?): List<AccessibilityNodeInfo> {
        val out = mutableListOf<AccessibilityNodeInfo>()
        if (root == null) return out
        val stack = ArrayDeque<AccessibilityNodeInfo>()
        stack.addLast(root)
        while (stack.isNotEmpty()) {
            val node = stack.removeLast()
            out.add(node)
            for (i in 0 until node.childCount) {
                node.getChild(i)?.let { stack.addLast(it) }
            }
        }
        return out
    }

    /** Returns the best-matching single node for a selector, or null if none matched. */
    fun find(root: AccessibilityNodeInfo?, selector: Selector): AccessibilityNodeInfo? {
        val candidates = findAll(root, selector)
        if (candidates.isEmpty()) return null
        // Prefer clickable, visible, enabled nodes over containers.
        return candidates.sortedByDescending { scoreNode(it) }.first()
    }

    fun findAll(root: AccessibilityNodeInfo?, selector: Selector): List<AccessibilityNodeInfo> {
        if (root == null) return emptyList()

        selector.resourceId?.let {
            val byId = root.findAccessibilityNodeInfosByViewId(it)
            if (byId.isNotEmpty()) return byId.filterNotNull()
        }

        if (selector.text != null) {
            val byText = root.findAccessibilityNodeInfosByText(selector.text)
            val exact = byText.filterNotNull().filter { it.text?.toString() == selector.text }
            if (exact.isNotEmpty()) return exact
            if (byText.isNotEmpty()) return byText.filterNotNull()
        }

        val all = collectAll(root)

        selector.partialText?.let { partial ->
            val matches = all.filter { it.text?.toString()?.contains(partial, ignoreCase = true) == true }
            if (matches.isNotEmpty()) return matches
        }

        selector.regex?.let { re ->
            val matches = all.filter { it.text?.toString()?.let { t -> re.containsMatchIn(t) } == true }
            if (matches.isNotEmpty()) return matches
        }

        selector.contentDescription?.let { desc ->
            val matches = all.filter {
                it.contentDescription?.toString()?.contains(desc, ignoreCase = true) == true
            }
            if (matches.isNotEmpty()) return matches
        }

        selector.className?.let { cls ->
            val matches = all.filter { it.className?.toString() == cls }
            if (matches.isNotEmpty()) return matches
        }

        return emptyList()
    }

    private fun scoreNode(node: AccessibilityNodeInfo): Int {
        var score = 0
        if (node.isClickable) score += 3
        if (node.isEnabled) score += 2
        if (node.isVisibleToUser) score += 2
        if (node.isFocused) score += 1
        return score
    }

    /** Serializes a node tree to JSON for readScreen()/test mode, matching the PRD's field list. */
    fun toJson(node: AccessibilityNodeInfo, depth: Int = 0, maxDepth: Int = 40): JSONObject {
        val obj = JSONObject()
        val bounds = Rect()
        node.getBoundsInScreen(bounds)
        obj.put("text", node.text?.toString())
        obj.put("contentDescription", node.contentDescription?.toString())
        obj.put("resourceId", node.viewIdResourceName)
        obj.put("className", node.className?.toString())
        obj.put("clickable", node.isClickable)
        obj.put("enabled", node.isEnabled)
        obj.put("selected", node.isSelected)
        obj.put("focused", node.isFocused)
        obj.put("editable", node.isEditable)
        obj.put("scrollable", node.isScrollable)
        obj.put("bounds", JSONObject().apply {
            put("left", bounds.left); put("top", bounds.top)
            put("right", bounds.right); put("bottom", bounds.bottom)
        })
        if (depth < maxDepth) {
            val children = JSONArray()
            for (i in 0 until node.childCount) {
                node.getChild(i)?.let { children.put(toJson(it, depth + 1, maxDepth)) }
            }
            obj.put("children", children)
        }
        return obj
    }
}
