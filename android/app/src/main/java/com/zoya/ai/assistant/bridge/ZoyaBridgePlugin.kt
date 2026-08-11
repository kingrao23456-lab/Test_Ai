package com.zoya.ai.assistant.bridge

import android.Manifest
import android.content.Intent
import android.media.AudioManager
import android.media.projection.MediaProjectionManager
import android.provider.Settings
import androidx.core.app.ActivityCompat
import com.getcapacitor.JSObject
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.CapacitorPlugin
import com.getcapacitor.annotation.Permission
import com.zoya.ai.assistant.accessibility.NodeFinder
import com.zoya.ai.assistant.camera.CameraController
import com.zoya.ai.assistant.ocr.OCRManager
import com.zoya.ai.assistant.scheduler.TaskScheduler
import com.zoya.ai.assistant.settings.SystemSettingsController
import com.zoya.ai.assistant.storage.LocalStore
import com.zoya.ai.assistant.workflow.Workflow
import com.zoya.ai.assistant.workflow.WorkflowEngine
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.json.JSONObject

/**
 * Every method here returns a structured {status, message, data} object to JS — never a bare
 * boolean, and never a fabricated success. See BridgeResult / ResultStatus.
 */
@CapacitorPlugin(
    name = "ZoyaBridge",
    permissions = [
        Permission(strings = [Manifest.permission.CAMERA], alias = "camera"),
        Permission(strings = [Manifest.permission.RECORD_AUDIO], alias = "microphone"),
        Permission(strings = [Manifest.permission.POST_NOTIFICATIONS], alias = "notifications")
    ]
)
class ZoyaBridgePlugin : Plugin() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private lateinit var engine: AutomationEngine
    private lateinit var appManager: AppManager
    private lateinit var settingsController: SystemSettingsController
    private lateinit var scheduler: TaskScheduler
    private lateinit var store: LocalStore
    private lateinit var camera: CameraController
    private val ocr = OCRManager()
    private var workflowEngine: WorkflowEngine? = null

    override fun load() {
        engine = AutomationEngine(context)
        appManager = AppManager(context)
        settingsController = SystemSettingsController(context)
        scheduler = TaskScheduler(context)
        store = LocalStore(context)
        camera = CameraController(context)
    }

    private fun PluginCall.reply(result: BridgeResult) {
        val obj = JSObject()
        val json = result.toJson()
        json.keys().forEach { key -> obj.put(key, json.get(key)) }
        resolve(obj)
    }

    // ---------- Permissions ----------

    @PluginMethod
    fun requestPermission(call: PluginCall) {
        when (call.getString("permission")) {
            "camera" -> requestPermissionForAlias("camera", call, "cameraPermsCallback")
            "microphone" -> requestPermissionForAlias("microphone", call, "micPermsCallback")
            "notifications" -> requestPermissionForAlias("notifications", call, "notifPermsCallback")
            "accessibility" -> {
                context.startActivity(
                    Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
                call.reply(BridgeResult.success("Opened Accessibility settings; user must enable manually"))
            }
            else -> call.reply(BridgeResult.unsupported("Unknown permission key"))
        }
    }

    @com.getcapacitor.annotation.PermissionCallback
    private fun cameraPermsCallback(call: PluginCall) = call.reply(
        if (getPermissionState("camera") == com.getcapacitor.PermissionState.GRANTED)
            BridgeResult.success("camera granted") else BridgeResult.permissionRequired("CAMERA")
    )

    @com.getcapacitor.annotation.PermissionCallback
    private fun micPermsCallback(call: PluginCall) = call.reply(
        if (getPermissionState("microphone") == com.getcapacitor.PermissionState.GRANTED)
            BridgeResult.success("microphone granted") else BridgeResult.permissionRequired("RECORD_AUDIO")
    )

    @com.getcapacitor.annotation.PermissionCallback
    private fun notifPermsCallback(call: PluginCall) = call.reply(
        if (getPermissionState("notifications") == com.getcapacitor.PermissionState.GRANTED)
            BridgeResult.success("notifications granted") else BridgeResult.permissionRequired("POST_NOTIFICATIONS")
    )

    @PluginMethod
    fun getPermissionStatus(call: PluginCall) {
        val result = JSObject()
        result.put("camera", getPermissionState("camera").toString())
        result.put("microphone", getPermissionState("microphone").toString())
        result.put("notifications", getPermissionState("notifications").toString())
        result.put("accessibility", engine.isAccessibilityEnabled())
        call.resolve(result)
    }

    // ---------- App management ----------

    @PluginMethod
    fun launchApp(call: PluginCall) {
        val pkg = call.getString("packageName") ?: return call.reply(BridgeResult.failure("packageName is required"))
        call.reply(appManager.launchApp(pkg))
    }

    @PluginMethod
    fun getInstalledApps(call: PluginCall) = call.reply(appManager.getInstalledApps(call.getString("query")))

    @PluginMethod
    fun getCurrentApp(call: PluginCall) = call.reply(appManager.getCurrentApp())

    // ---------- Gestures / UI interaction ----------

    @PluginMethod
    fun tap(call: PluginCall) {
        val x = call.getFloat("x") ?: return call.reply(BridgeResult.failure("x is required"))
        val y = call.getFloat("y") ?: return call.reply(BridgeResult.failure("y is required"))
        scope.launch { call.reply(engine.tap(x, y)) }
    }

    @PluginMethod
    fun longPress(call: PluginCall) {
        val x = call.getFloat("x") ?: return call.reply(BridgeResult.failure("x is required"))
        val y = call.getFloat("y") ?: return call.reply(BridgeResult.failure("y is required"))
        val duration = call.getLong("durationMs") ?: 700L
        val service = com.zoya.ai.assistant.accessibility.ZoyaAccessibilityService.instance
            ?: return call.reply(BridgeResult.permissionRequired("ACCESSIBILITY_SERVICE"))
        scope.launch {
            val ok = service.gestures.longPress(x, y, duration)
            call.reply(if (ok) BridgeResult.success() else BridgeResult.failure("Gesture rejected"))
        }
    }

    @PluginMethod
    fun swipe(call: PluginCall) {
        val x1 = call.getFloat("x1") ?: return call.reply(BridgeResult.failure("x1 is required"))
        val y1 = call.getFloat("y1") ?: return call.reply(BridgeResult.failure("y1 is required"))
        val x2 = call.getFloat("x2") ?: return call.reply(BridgeResult.failure("x2 is required"))
        val y2 = call.getFloat("y2") ?: return call.reply(BridgeResult.failure("y2 is required"))
        val duration = call.getLong("durationMs") ?: 300L
        scope.launch { call.reply(engine.swipe(x1, y1, x2, y2, duration)) }
    }

    @PluginMethod
    fun scroll(call: PluginCall) {
        val forward = call.getBoolean("forward") ?: true
        val selector = selectorFromCall(call)
        scope.launch {
            call.reply(engine.findAndAct(selector, { node ->
                com.zoya.ai.assistant.accessibility.ZoyaAccessibilityService.instance?.performScroll(node, forward) ?: false
            }))
        }
    }

    @PluginMethod
    fun gesture(call: PluginCall) {
        // Generic multi-point path gesture, e.g. for replaying a recorded gesture.
        val pointsArr = call.getArray("points") ?: return call.reply(BridgeResult.failure("points array is required"))
        val duration = call.getLong("durationMs") ?: 300L
        val service = com.zoya.ai.assistant.accessibility.ZoyaAccessibilityService.instance
            ?: return call.reply(BridgeResult.permissionRequired("ACCESSIBILITY_SERVICE"))
        val points = mutableListOf<Pair<Float, Float>>()
        for (i in 0 until pointsArr.length()) {
            val p = pointsArr.getJSONObject(i)
            points.add(Pair(p.getDouble("x").toFloat(), p.getDouble("y").toFloat()))
        }
        scope.launch {
            val ok = service.gestures.customPath(points, duration)
            call.reply(if (ok) BridgeResult.success() else BridgeResult.failure("Gesture rejected"))
        }
    }

    @PluginMethod
    fun typeText(call: PluginCall) {
        val text = call.getString("text") ?: return call.reply(BridgeResult.failure("text is required"))
        val selector = selectorFromCall(call)
        scope.launch { call.reply(engine.typeText(selector, text)) }
    }

    @PluginMethod
    fun readScreen(call: PluginCall) = call.reply(engine.readScreen())

    @PluginMethod
    fun findUIElement(call: PluginCall) = call.reply(engine.findElement(selectorFromCall(call)))

    @PluginMethod
    fun pressBack(call: PluginCall) = call.reply(engine.pressBack())

    @PluginMethod
    fun pressHome(call: PluginCall) = call.reply(engine.pressHome())

    private fun selectorFromCall(call: PluginCall): NodeFinder.Selector = NodeFinder.Selector(
        text = call.getString("text"),
        partialText = call.getString("partialText"),
        regex = call.getString("regex")?.let { Regex(it) },
        contentDescription = call.getString("contentDescription"),
        resourceId = call.getString("resourceId"),
        className = call.getString("className")
    )

    // ---------- Settings / device controls ----------

    @PluginMethod
    fun openSettings(call: PluginCall) {
        val screen = call.getString("screen") ?: return call.reply(BridgeResult.failure("screen is required"))
        call.reply(settingsController.open(screen))
    }

    @PluginMethod
    fun setBrightness(call: PluginCall) {
        val value = call.getInt("value") ?: return call.reply(BridgeResult.failure("value is required"))
        call.reply(settingsController.setBrightness(value))
    }

    @PluginMethod
    fun setVolume(call: PluginCall) {
        val value = call.getInt("value") ?: return call.reply(BridgeResult.failure("value is required"))
        val stream = when (call.getString("stream")) {
            "ring" -> AudioManager.STREAM_RING
            "notification" -> AudioManager.STREAM_NOTIFICATION
            "alarm" -> AudioManager.STREAM_ALARM
            else -> AudioManager.STREAM_MUSIC
        }
        call.reply(settingsController.setVolume(stream, value))
    }

    // ---------- Camera ----------

    @PluginMethod
    fun takePhoto(call: PluginCall) {
        if (getPermissionState("camera") != com.getcapacitor.PermissionState.GRANTED) {
            return call.reply(BridgeResult.permissionRequired("CAMERA"))
        }
        val activity = activity ?: return call.reply(BridgeResult.failure("No active activity"))
        val useFront = call.getBoolean("front") ?: false
        scope.launch {
            val bindResult = camera.bind(activity as androidx.lifecycle.LifecycleOwner, useFront)
            if (bindResult.status != ResultStatus.SUCCESS) return@launch call.reply(bindResult)
            call.reply(camera.takePhoto())
        }
    }

    // ---------- Screen capture / OCR ----------

    @PluginMethod
    fun captureScreen(call: PluginCall) {
        val mgr = context.getSystemService(android.content.Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val activity = activity ?: return call.reply(BridgeResult.failure("No active activity"))
        // Requesting MediaProjection requires a startActivityForResult flow; wire this to your
        // MainActivity's onActivityResult and forward the resultCode/data Intent into
        // ScreenCaptureService (EXTRA_RESULT_CODE / EXTRA_DATA) before calling captureFrame().
        activity.startActivityForResult(mgr.createScreenCaptureIntent(), SCREEN_CAPTURE_REQUEST)
        call.reply(BridgeResult.success("Screen capture consent dialog shown"))
    }

    @PluginMethod
    fun performOCR(call: PluginCall) {
        // Expects a bitmap to already have been captured via captureScreen(); left as an
        // extension point wiring ScreenCaptureService.captureFrame() -> OCRManager.recognize().
        call.reply(BridgeResult.unsupported("Call captureScreen() first, then performOCR() reads that frame"))
    }

    // ---------- Workflow / automation control ----------

    @PluginMethod
    fun startAutomation(call: PluginCall) {
        val workflowJson = call.data.optJSONObject("workflow")
            ?: return call.reply(BridgeResult.failure("workflow object is required"))
        val workflow = Workflow.fromJson(workflowJson)
        store.upsert(LocalStore.WORKFLOWS, "id", workflowJson)
        val wfEngine = WorkflowEngine(engine)
        workflowEngine = wfEngine
        scope.launch {
            val result = wfEngine.run(workflow) { status ->
                notifyListeners("automationStatus", JSObject().apply {
                    put("type", status.optString("type"))
                    put("action", status.optString("action"))
                    put("status", status.optString("status"))
                    put("message", status.optString("message"))
                })
            }
            store.appendHistory(JSONObject().apply {
                put("workflowId", workflow.id)
                put("status", result.status.name.lowercase())
                put("message", result.message)
                put("timestamp", System.currentTimeMillis())
            })
            call.reply(result)
        }
    }

    @PluginMethod
    fun stopAutomation(call: PluginCall) {
        workflowEngine?.cancel()
        call.reply(BridgeResult.success("Automation stop requested"))
    }

    @PluginMethod
    fun getAutomationStatus(call: PluginCall) {
        val obj = JSObject()
        obj.put("running", workflowEngine != null)
        obj.put("accessibilityEnabled", engine.isAccessibilityEnabled())
        call.resolve(obj)
    }

    @PluginMethod
    fun scheduleTask(call: PluginCall) {
        val workflowId = call.getString("workflowId") ?: return call.reply(BridgeResult.failure("workflowId is required"))
        val kind = call.getString("kind") ?: "one_time"
        val taskId = if (kind == "recurring") {
            scheduler.scheduleRecurring(workflowId, call.getInt("intervalMinutes")?.toLong() ?: 60L)
        } else {
            scheduler.scheduleOneTime(workflowId, call.getInt("delayMs")?.toLong() ?: 0L)
        }
        call.reply(BridgeResult.success("Scheduled", JSONObject().put("taskId", taskId)))
    }

    @PluginMethod
    fun getExecutionLogs(call: PluginCall) {
        val logs = store.readAll(LocalStore.EXECUTION_HISTORY)
        val obj = JSObject()
        obj.put("logs", logs)
        call.resolve(obj)
    }

    companion object {
        const val SCREEN_CAPTURE_REQUEST = 9821
    }
}

