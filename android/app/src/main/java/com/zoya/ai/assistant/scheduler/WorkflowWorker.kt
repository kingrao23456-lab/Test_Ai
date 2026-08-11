package com.zoya.ai.assistant.scheduler

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.zoya.ai.assistant.bridge.AutomationEngine
import com.zoya.ai.assistant.bridge.ResultStatus
import com.zoya.ai.assistant.storage.LocalStore
import com.zoya.ai.assistant.workflow.Workflow
import com.zoya.ai.assistant.workflow.WorkflowEngine
import org.json.JSONObject

class WorkflowWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val workflowId = inputData.getString(KEY_WORKFLOW_ID) ?: return Result.failure()
        val taskId = inputData.getString(KEY_TASK_ID) ?: ""
        val store = LocalStore(applicationContext)

        // Prevent duplicate execution if this worker is somehow still running from a prior fire.
        val history = store.readAll(LocalStore.EXECUTION_HISTORY)
        for (i in 0 until history.length()) {
            val h = history.getJSONObject(i)
            if (h.optString("taskId") == taskId && h.optString("status") == "running") {
                return Result.success() // already in progress, skip this trigger
            }
        }

        val workflows = store.readAll(LocalStore.WORKFLOWS)
        var workflowJson: JSONObject? = null
        for (i in 0 until workflows.length()) {
            val w = workflows.getJSONObject(i)
            if (w.optString("id") == workflowId) { workflowJson = w; break }
        }
        if (workflowJson == null) return Result.failure()

        val engine = AutomationEngine(applicationContext)
        val workflowEngine = WorkflowEngine(engine)
        val workflow = Workflow.fromJson(workflowJson)

        val result = workflowEngine.run(workflow) { /* per-step status could be surfaced via a broadcast */ }

        store.appendHistory(JSONObject().apply {
            put("taskId", taskId)
            put("workflowId", workflowId)
            put("status", result.status.name.lowercase())
            put("message", result.message)
            put("timestamp", System.currentTimeMillis())
        })

        return if (result.status == ResultStatus.SUCCESS) Result.success() else Result.retry()
    }

    companion object {
        const val KEY_WORKFLOW_ID = "workflowId"
        const val KEY_TASK_ID = "taskId"
    }
}
