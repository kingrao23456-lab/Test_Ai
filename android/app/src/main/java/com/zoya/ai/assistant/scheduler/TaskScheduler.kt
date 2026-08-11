package com.zoya.ai.assistant.scheduler

import android.content.Context
import androidx.work.*
import com.zoya.ai.assistant.storage.LocalStore
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.TimeUnit

/**
 * Deferrable background scheduling via WorkManager, which is Android's recommended API for
 * this (survives Doze/battery-optimization far better than a raw AlarmManager + wakelock, and
 * WorkManager itself falls back to AlarmManager internally on very old OS versions).
 */
class TaskScheduler(private val context: Context) {

    private val store = LocalStore(context)
    private val workManager = WorkManager.getInstance(context)

    fun scheduleOneTime(workflowId: String, delayMs: Long): String {
        val taskId = UUID.randomUUID().toString()
        val request = OneTimeWorkRequestBuilder<WorkflowWorker>()
            .setInitialDelay(delayMs, TimeUnit.MILLISECONDS)
            .setInputData(workDataOf(WorkflowWorker.KEY_WORKFLOW_ID to workflowId, WorkflowWorker.KEY_TASK_ID to taskId))
            .addTag(taskId)
            .build()
        workManager.enqueue(request)
        persistTask(taskId, workflowId, "one_time", enabled = true)
        return taskId
    }

    fun scheduleRecurring(workflowId: String, intervalMinutes: Long): String {
        val taskId = UUID.randomUUID().toString()
        val minInterval = intervalMinutes.coerceAtLeast(15) // WorkManager's periodic floor
        val request = PeriodicWorkRequestBuilder<WorkflowWorker>(minInterval, TimeUnit.MINUTES)
            .setInputData(workDataOf(WorkflowWorker.KEY_WORKFLOW_ID to workflowId, WorkflowWorker.KEY_TASK_ID to taskId))
            .addTag(taskId)
            .build()
        workManager.enqueueUniquePeriodicWork(taskId, ExistingPeriodicWorkPolicy.KEEP, request)
        persistTask(taskId, workflowId, "recurring", enabled = true)
        return taskId
    }

    fun cancel(taskId: String) {
        workManager.cancelAllWorkByTag(taskId)
        store.delete(LocalStore.SCHEDULED_TASKS, "id", taskId)
    }

    fun setEnabled(taskId: String, enabled: Boolean) {
        val items = store.readAll(LocalStore.SCHEDULED_TASKS)
        for (i in 0 until items.length()) {
            val obj = items.getJSONObject(i)
            if (obj.optString("id") == taskId) {
                obj.put("enabled", enabled)
                if (!enabled) workManager.cancelAllWorkByTag(taskId)
            }
        }
        store.writeAll(LocalStore.SCHEDULED_TASKS, items)
    }

    private fun persistTask(id: String, workflowId: String, kind: String, enabled: Boolean) {
        val obj = JSONObject().apply {
            put("id", id)
            put("workflowId", workflowId)
            put("kind", kind)
            put("enabled", enabled)
            put("createdAt", System.currentTimeMillis())
        }
        store.upsert(LocalStore.SCHEDULED_TASKS, "id", obj)
    }
}
