package com.zoya.ai.assistant.storage

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Lightweight persistent storage for the automation data model (workflows, gestures,
 * scheduled tasks, execution history, permission/device state, app profiles).
 * Uses one JSON file per collection under the app's private files dir — simple, dependency-free,
 * and easy to export/import (the PRD requires workflow import/export).
 */
class LocalStore(context: Context) {

    private val dir = File(context.filesDir, "zoya_store").apply { mkdirs() }

    private fun fileFor(collection: String) = File(dir, "$collection.json")

    @Synchronized
    fun readAll(collection: String): JSONArray {
        val file = fileFor(collection)
        if (!file.exists()) return JSONArray()
        return try {
            JSONArray(file.readText())
        } catch (e: Exception) {
            JSONArray()
        }
    }

    @Synchronized
    fun writeAll(collection: String, items: JSONArray) {
        fileFor(collection).writeText(items.toString())
    }

    @Synchronized
    fun upsert(collection: String, idField: String, item: JSONObject) {
        val items = readAll(collection)
        val id = item.optString(idField)
        var replaced = false
        for (i in 0 until items.length()) {
            if (items.getJSONObject(i).optString(idField) == id) {
                items.put(i, item)
                replaced = true
                break
            }
        }
        if (!replaced) items.put(item)
        writeAll(collection, items)
    }

    @Synchronized
    fun delete(collection: String, idField: String, id: String) {
        val items = readAll(collection)
        val filtered = JSONArray()
        for (i in 0 until items.length()) {
            val obj = items.getJSONObject(i)
            if (obj.optString(idField) != id) filtered.put(obj)
        }
        writeAll(collection, filtered)
    }

    @Synchronized
    fun appendHistory(entry: JSONObject, maxEntries: Int = 500) {
        val items = readAll("execution_history")
        items.put(entry)
        // Keep only the most recent maxEntries to avoid unbounded growth.
        val trimmed = if (items.length() > maxEntries) {
            JSONArray((items.length() - maxEntries until items.length()).map { items.get(it) })
        } else items
        writeAll("execution_history", trimmed)
    }

    companion object {
        const val WORKFLOWS = "workflows"
        const val GESTURES = "gestures"
        const val SCHEDULED_TASKS = "scheduled_tasks"
        const val EXECUTION_HISTORY = "execution_history"
        const val PERMISSION_STATES = "permission_states"
        const val DEVICE_CAPABILITIES = "device_capabilities"
        const val APP_PROFILES = "app_profiles"
    }
}
