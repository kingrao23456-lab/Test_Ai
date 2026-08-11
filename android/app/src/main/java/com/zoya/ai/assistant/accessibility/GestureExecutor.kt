package com.zoya.ai.assistant.accessibility

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Handler
import android.os.Looper
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

/**
 * Wraps Android's official gesture-injection API (GestureDescription / dispatchGesture),
 * as required by the PRD instead of any private/unsupported injection mechanism.
 */
class GestureExecutor(private val service: AccessibilityService) {

    private var currentCallback: AccessibilityService.GestureResultCallback? = null

    suspend fun tap(x: Float, y: Float, durationMs: Long = 60): Boolean = dispatch {
        val path = Path().apply { moveTo(x, y) }
        GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, durationMs))
            .build()
    }

    suspend fun doubleTap(x: Float, y: Float, gapMs: Long = 120): Boolean {
        val first = tap(x, y)
        if (!first) return false
        kotlinx.coroutines.delay(gapMs)
        return tap(x, y)
    }

    suspend fun longPress(x: Float, y: Float, durationMs: Long = 700): Boolean = dispatch {
        val path = Path().apply { moveTo(x, y) }
        GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, durationMs))
            .build()
    }

    suspend fun swipe(
        x1: Float, y1: Float, x2: Float, y2: Float,
        durationMs: Long = 300, startDelayMs: Long = 0
    ): Boolean = dispatch {
        val path = Path().apply { moveTo(x1, y1); lineTo(x2, y2) }
        GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, startDelayMs, durationMs))
            .build()
    }

    /** A custom multi-point path, e.g. for a recorded gesture replay. */
    suspend fun customPath(points: List<Pair<Float, Float>>, durationMs: Long = 300): Boolean = dispatch {
        if (points.isEmpty()) return@dispatch null
        val path = Path().apply {
            moveTo(points.first().first, points.first().second)
            for (p in points.drop(1)) lineTo(p.first, p.second)
        }
        GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, durationMs))
            .build()
    }

    /** Two-finger pinch/zoom where the API level and target app support it. */
    suspend fun pinch(
        centerX: Float, centerY: Float, startSpacing: Float, endSpacing: Float, durationMs: Long = 400
    ): Boolean = dispatch {
        val p1Start = Path().apply { moveTo(centerX - startSpacing / 2, centerY) }
        p1Start.lineTo(centerX - endSpacing / 2, centerY)
        val p2Start = Path().apply { moveTo(centerX + startSpacing / 2, centerY) }
        p2Start.lineTo(centerX + endSpacing / 2, centerY)
        GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(p1Start, 0, durationMs))
            .addStroke(GestureDescription.StrokeDescription(p2Start, 0, durationMs))
            .build()
    }

    fun cancelCurrent() {
        // dispatchGesture doesn't expose a direct cancel handle per-call; the recommended approach
        // is to stop issuing new strokes and let the in-flight one finish (Android does not allow
        // aborting a gesture already sent to the input system). We simply drop our callback ref.
        currentCallback = null
    }

    private suspend fun dispatch(build: () -> GestureDescription?): Boolean {
        val gesture = build() ?: return false
        return suspendCancellableCoroutine { cont ->
            val callback = object : AccessibilityService.GestureResultCallback() {
                override fun onCompleted(gestureDescription: GestureDescription?) {
                    if (cont.isActive) cont.resume(true)
                }
                override fun onCancelled(gestureDescription: GestureDescription?) {
                    if (cont.isActive) cont.resume(false)
                }
            }
            currentCallback = callback
            val dispatched = service.dispatchGesture(gesture, callback, Handler(Looper.getMainLooper()))
            if (!dispatched && cont.isActive) cont.resume(false)
        }
    }
}
