package com.zoya.ai.assistant.workflow

import com.zoya.ai.assistant.accessibility.NodeFinder
import com.zoya.ai.assistant.bridge.AutomationEngine
import com.zoya.ai.assistant.bridge.BridgeResult
import com.zoya.ai.assistant.bridge.ResultStatus
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject

/**
 * Interprets a Workflow against the AutomationEngine. Supports the condition types listed in
 * the PRD: IF / ELSE / WHILE / REPEAT / WAIT / TIMEOUT / VERIFY, plus package / visible-text /
 * accessibility-node / screen-state checks (delegated to the engine's readScreen/findElement).
 */
class WorkflowEngine(private val engine: AutomationEngine) {

    @Volatile private var cancelled = false
    private val log = mutableListOf<JSONObject>()

    fun cancel() { cancelled = true; engine.cancelAll() }

    suspend fun run(workflow: Workflow, onStatus: (JSONObject) -> Unit): BridgeResult {
        cancelled = false
        engine.resetCancellation()
        log.clear()
        for (step in workflow.steps) {
            if (cancelled) return BridgeResult.failure("Workflow cancelled")
            val result = runStep(step, onStatus)
            if (result.status != ResultStatus.SUCCESS && step.type == "action") {
                return BridgeResult.failure("Workflow stopped at step '${step.action}': ${result.message}")
            }
        }
        return BridgeResult.success("Workflow completed", JSONObject().put("log", JSONArray(log)))
    }

    private suspend fun runStep(step: WorkflowStep, onStatus: (JSONObject) -> Unit): BridgeResult {
        val result = withTimeoutOrNull(step.timeoutMs) {
            executeWithRetry(step)
        } ?: BridgeResult.timeout("Step '${step.type}:${step.action}' timed out after ${step.timeoutMs}ms")

        val entry = JSONObject().apply {
            put("type", step.type)
            put("action", step.action)
            put("status", result.status.name.lowercase())
            put("message", result.message)
        }
        log.add(entry)
        onStatus(entry)
        return result
    }

    private suspend fun executeWithRetry(step: WorkflowStep): BridgeResult {
        var attempt = 0
        var last: BridgeResult
        do {
            last = executeOnce(step)
            attempt++
            if (last.status != ResultStatus.SUCCESS && attempt <= step.retries) delay(step.retryDelayMs)
        } while (last.status != ResultStatus.SUCCESS && attempt <= step.retries)
        return last
    }

    private suspend fun executeOnce(step: WorkflowStep): BridgeResult {
        return when (step.type) {
            "wait" -> {
                delay(step.params.optLong("ms", 500))
                BridgeResult.success("Waited")
            }
            "if" -> {
                val conditionMet = evaluateCondition(step.condition)
                val branch = if (conditionMet) step.thenSteps else step.elseSteps
                runBranch(branch)
            }
            "while" -> {
                var iterations = 0
                val maxIterations = step.params.optInt("maxIterations", 50)
                while (evaluateCondition(step.condition) && iterations < maxIterations && !cancelled) {
                    runBranch(step.thenSteps)
                    iterations++
                }
                BridgeResult.success("While loop ran $iterations time(s)")
            }
            "repeat" -> {
                val times = step.params.optInt("times", 1)
                repeat(times) { if (!cancelled) runBranch(step.thenSteps) }
                BridgeResult.success("Repeated $times time(s)")
            }
            "verify" -> evaluateVerification(step.condition)
            "action" -> executeAction(step)
            else -> BridgeResult.unsupported("Unknown step type '${step.type}'")
        }
    }

    private suspend fun runBranch(steps: List<WorkflowStep>): BridgeResult {
        for (s in steps) {
            if (cancelled) return BridgeResult.failure("Cancelled")
            val r = executeWithRetry(s)
            if (r.status != ResultStatus.SUCCESS) return r
        }
        return BridgeResult.success()
    }

    private fun evaluateCondition(condition: JSONObject?): Boolean {
        condition ?: return false
        return when (condition.optString("kind")) {
            "package" -> engine.readScreen().data?.optString("package") == condition.optString("value")
            "visibleText" -> {
                val text = condition.optString("value")
                val screen = engine.readScreen()
                screen.status == ResultStatus.SUCCESS && screen.data.toString().contains(text)
            }
            "accessibilityNode" -> {
                val selector = NodeFinder.Selector(
                    text = condition.optString("text", null),
                    resourceId = condition.optString("resourceId", null)
                )
                engine.findElement(selector).status == ResultStatus.SUCCESS
            }
            else -> false
        }
    }

    private fun evaluateVerification(condition: JSONObject?): BridgeResult {
        val met = evaluateCondition(condition)
        return if (met) BridgeResult.success("Verified") else BridgeResult.failure("Verification failed")
    }

    private suspend fun executeAction(step: WorkflowStep): BridgeResult {
        val p = step.params
        return when (step.action) {
            "tap" -> engine.tap(p.optDouble("x").toFloat(), p.optDouble("y").toFloat())
            "swipe" -> engine.swipe(
                p.optDouble("x1").toFloat(), p.optDouble("y1").toFloat(),
                p.optDouble("x2").toFloat(), p.optDouble("y2").toFloat(),
                p.optLong("durationMs", 300)
            )
            "typeText" -> engine.typeText(
                NodeFinder.Selector(resourceId = p.optString("resourceId", null), text = p.optString("targetText", null)),
                p.optString("text")
            )
            "pressBack" -> engine.pressBack()
            "pressHome" -> engine.pressHome()
            else -> BridgeResult.unsupported("Unknown action '${step.action}'")
        }
    }
}
