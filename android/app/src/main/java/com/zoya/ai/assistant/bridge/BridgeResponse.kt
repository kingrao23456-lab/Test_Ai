package com.zoya.ai.assistant.bridge

import org.json.JSONObject

/**
 * Every bridge call returns one of these five structured statuses.
 * The web app must NEVER be told an action succeeded unless Android actually confirmed it.
 */
enum class ResultStatus { SUCCESS, FAILURE, PERMISSION_REQUIRED, TIMEOUT, UNSUPPORTED }

data class BridgeResult(
    val status: ResultStatus,
    val message: String = "",
    val data: JSONObject? = null
) {
    fun toJson(): JSONObject {
        val obj = JSONObject()
        obj.put("status", status.name.lowercase())
        obj.put("message", message)
        obj.put("data", data ?: JSONObject())
        return obj
    }

    companion object {
        fun success(message: String = "ok", data: JSONObject? = null) =
            BridgeResult(ResultStatus.SUCCESS, message, data)

        fun failure(message: String) = BridgeResult(ResultStatus.FAILURE, message)

        fun permissionRequired(permission: String) =
            BridgeResult(ResultStatus.PERMISSION_REQUIRED, "Missing permission: $permission")

        fun timeout(message: String = "Action timed out") =
            BridgeResult(ResultStatus.TIMEOUT, message)

        fun unsupported(message: String) = BridgeResult(ResultStatus.UNSUPPORTED, message)
    }
}
