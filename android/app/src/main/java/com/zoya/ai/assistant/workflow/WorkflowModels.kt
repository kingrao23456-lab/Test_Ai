package com.zoya.ai.assistant.workflow

import org.json.JSONArray
import org.json.JSONObject

/**
 * A workflow is a JSON document (created/imported from the web app) made of steps.
 * Kept as plain JSON rather than Room entities to avoid extra build-time annotation
 * processing while still being fully persistent (see storage/LocalStore.kt).
 */
data class WorkflowStep(
    val type: String,              // "action" | "if" | "while" | "repeat" | "wait" | "verify"
    val action: String? = null,    // e.g. "tap", "typeText", "launchApp"
    val params: JSONObject = JSONObject(),
    val condition: JSONObject? = null,
    val thenSteps: List<WorkflowStep> = emptyList(),
    val elseSteps: List<WorkflowStep> = emptyList(),
    val timeoutMs: Long = 10_000,
    val retries: Int = 1,
    val retryDelayMs: Long = 300
) {
    companion object {
        fun fromJson(obj: JSONObject): WorkflowStep {
            fun stepList(key: String): List<WorkflowStep> {
                val arr = obj.optJSONArray(key) ?: JSONArray()
                return (0 until arr.length()).map { fromJson(arr.getJSONObject(it)) }
            }
            return WorkflowStep(
                type = obj.optString("type", "action"),
                action = obj.optString("action", null),
                params = obj.optJSONObject("params") ?: JSONObject(),
                condition = obj.optJSONObject("condition"),
                thenSteps = stepList("then"),
                elseSteps = stepList("else"),
                timeoutMs = obj.optLong("timeoutMs", 10_000),
                retries = obj.optInt("retries", 1),
                retryDelayMs = obj.optLong("retryDelayMs", 300)
            )
        }
    }
}

data class Workflow(
    val id: String,
    val name: String,
    val version: Int = 1,
    val steps: List<WorkflowStep>
) {
    companion object {
        fun fromJson(obj: JSONObject): Workflow {
            val stepsArr = obj.optJSONArray("steps") ?: JSONArray()
            val steps = (0 until stepsArr.length()).map { WorkflowStep.fromJson(stepsArr.getJSONObject(it)) }
            return Workflow(
                id = obj.optString("id"),
                name = obj.optString("name", "Untitled workflow"),
                version = obj.optInt("version", 1),
                steps = steps
            )
        }
    }
}
