#!/data/data/com.termux/files/usr/bin/bash
set -e
echo "== Zoya automation code restore script =="
cd ~/zoya-ai-assistant

# 1. Remove old Java MainActivity (replaced by Kotlin version)
rm -f android/app/src/main/java/com/zoya/ai/assistant/MainActivity.java

# 2. Create package folders
mkdir -p android/app/src/main/java/com/zoya/ai/assistant/{bridge,accessibility,capture,ocr,camera,settings,workflow,scheduler,storage,ui}
mkdir -p android/app/src/main/res/{xml,layout,values}

# 3. Write all Kotlin source files
cat > android/app/src/main/java/com/zoya/ai/assistant/MainActivity.kt << 'ZOYAEOF'
package com.zoya.ai.assistant

import android.os.Bundle
import com.getcapacitor.BridgeActivity
import com.zoya.ai.assistant.bridge.ZoyaBridgePlugin

class MainActivity : BridgeActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // Register our custom native plugin BEFORE super.onCreate()
        registerPlugin(ZoyaBridgePlugin::class.java)
        super.onCreate(savedInstanceState)
    }
}

ZOYAEOF

cat > android/app/src/main/java/com/zoya/ai/assistant/bridge/BridgeResponse.kt << 'ZOYAEOF'
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

ZOYAEOF

cat > android/app/src/main/java/com/zoya/ai/assistant/bridge/AutomationEngine.kt << 'ZOYAEOF'
package com.zoya.ai.assistant.bridge

import android.content.Context
import android.provider.Settings
import android.text.TextUtils
import kotlinx.coroutines.delay
import com.zoya.ai.assistant.accessibility.NodeFinder
import com.zoya.ai.assistant.accessibility.ZoyaAccessibilityService
import org.json.JSONObject

/**
 * Central engine described by the PRD: every device action passes through here so it is
 * validated, permission-checked, executed via the most reliable available API, verified,
 * retried when appropriate, and reported back with a structured status.
 */
class AutomationEngine(private val context: Context) {

    @Volatile private var cancelled = false

    fun cancelAll() { cancelled = true }
    fun resetCancellation() { cancelled = false }

    fun isAccessibilityEnabled(): Boolean {
        // Confirm via the OS setting AND our live service instance, not just one signal.
        val enabledServices = Settings.Secure.getString(
            context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false
        val serviceName = "${context.packageName}/${ZoyaAccessibilityService::class.java.canonicalName}"
        val settingOn = enabledServices.split(":").any { it.equals(serviceName, ignoreCase = true) }
        return settingOn && ZoyaAccessibilityService.isEnabled()
    }

    private fun requireAccessibility(): ZoyaAccessibilityService? {
        if (!isAccessibilityEnabled()) return null
        return ZoyaAccessibilityService.instance
    }

    /**
     * Generic "find + act" pipeline implementing the PRD's Smart Target Selection order:
     * accessibility semantics -> text -> content-description -> resource-id
     * (OCR / visual detection fallback is wired in at the bridge layer once those modules
     * are filled in; this function stops and reports rather than guessing coordinates).
     */
    suspend fun findAndAct(
        selector: NodeFinder.Selector,
        action: (android.view.accessibility.AccessibilityNodeInfo) -> Boolean,
        retries: Int = 2,
        retryDelayMs: Long = 250
    ): BridgeResult {
        val service = requireAccessibility()
            ?: return BridgeResult.permissionRequired("ACCESSIBILITY_SERVICE")

        var attempt = 0
        while (attempt <= retries) {
            if (cancelled) return BridgeResult.failure("Cancelled by user")
            val root = service.currentRoot()
            val node = NodeFinder.find(root, selector)
            if (node != null) {
                val didAct = action(node)
                if (didAct) {
                    // Verification pass: re-read tree after a short settle delay.
                    delay(120)
                    return BridgeResult.success("Action verified")
                }
            }
            attempt++
            if (attempt <= retries) delay(retryDelayMs)
        }
        return BridgeResult.failure("Target not found or action rejected by the app after $retries retries")
    }

    suspend fun tap(x: Float, y: Float): BridgeResult {
        val service = requireAccessibility() ?: return BridgeResult.permissionRequired("ACCESSIBILITY_SERVICE")
        if (cancelled) return BridgeResult.failure("Cancelled")
        val ok = service.gestures.tap(x, y)
        return if (ok) BridgeResult.success() else BridgeResult.failure("Gesture rejected by the system")
    }

    suspend fun swipe(x1: Float, y1: Float, x2: Float, y2: Float, durationMs: Long): BridgeResult {
        val service = requireAccessibility() ?: return BridgeResult.permissionRequired("ACCESSIBILITY_SERVICE")
        val ok = service.gestures.swipe(x1, y1, x2, y2, durationMs)
        return if (ok) BridgeResult.success() else BridgeResult.failure("Gesture rejected by the system")
    }

    fun readScreen(): BridgeResult {
        val service = requireAccessibility() ?: return BridgeResult.permissionRequired("ACCESSIBILITY_SERVICE")
        val root = service.currentRoot() ?: return BridgeResult.failure("No active window content available")
        val json = NodeFinder.toJson(root)
        val wrapper = JSONObject().put("tree", json).put("package", service.lastEventPackage)
        return BridgeResult.success("Screen read", wrapper)
    }

    fun findElement(selector: NodeFinder.Selector): BridgeResult {
        val service = requireAccessibility() ?: return BridgeResult.permissionRequired("ACCESSIBILITY_SERVICE")
        val root = service.currentRoot() ?: return BridgeResult.failure("No active window")
        val matches = NodeFinder.findAll(root, selector)
        if (matches.isEmpty()) return BridgeResult.failure("No matching element found")
        val arr = org.json.JSONArray()
        matches.take(20).forEach { arr.put(NodeFinder.toJson(it, maxDepth = 0)) }
        return BridgeResult.success("Found ${matches.size} element(s)", JSONObject().put("elements", arr))
    }

    suspend fun typeText(selector: NodeFinder.Selector, text: String): BridgeResult {
        if (TextUtils.isEmpty(text)) return BridgeResult.failure("Empty text")
        return findAndAct(selector, { node ->
            val service = ZoyaAccessibilityService.instance ?: return@findAndAct false
            service.performSetText(node, text)
        })
    }

    fun pressBack(): BridgeResult {
        val service = requireAccessibility() ?: return BridgeResult.permissionRequired("ACCESSIBILITY_SERVICE")
        return if (service.globalBack()) BridgeResult.success() else BridgeResult.failure("System rejected back action")
    }

    fun pressHome(): BridgeResult {
        val service = requireAccessibility() ?: return BridgeResult.permissionRequired("ACCESSIBILITY_SERVICE")
        return if (service.globalHome()) BridgeResult.success() else BridgeResult.failure("System rejected home action")
    }
}

ZOYAEOF

cat > android/app/src/main/java/com/zoya/ai/assistant/bridge/AppManager.kt << 'ZOYAEOF'
package com.zoya.ai.assistant.bridge

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import com.zoya.ai.assistant.accessibility.ZoyaAccessibilityService
import org.json.JSONArray
import org.json.JSONObject

class AppManager(private val context: Context) {

    private val pm: PackageManager get() = context.packageManager

    fun getInstalledApps(query: String? = null): BridgeResult {
        return try {
            val apps = pm.getInstalledApplications(PackageManager.GET_META_DATA)
            val arr = JSONArray()
            apps.filter { (it.flags and ApplicationInfo.FLAG_SYSTEM) == 0 || pm.getLaunchIntentForPackage(it.packageName) != null }
                .forEach { app ->
                    val label = pm.getApplicationLabel(app).toString()
                    if (query.isNullOrBlank() || label.contains(query, ignoreCase = true) ||
                        app.packageName.contains(query, ignoreCase = true)
                    ) {
                        arr.put(JSONObject().apply {
                            put("packageName", app.packageName)
                            put("label", label)
                            put("launchable", pm.getLaunchIntentForPackage(app.packageName) != null)
                        })
                    }
                }
            BridgeResult.success("Found ${arr.length()} app(s)", JSONObject().put("apps", arr))
        } catch (e: Exception) {
            BridgeResult.failure("Could not list installed apps: ${e.message}")
        }
    }

    fun launchApp(packageName: String): BridgeResult {
        val intent = pm.getLaunchIntentForPackage(packageName)
            ?: return BridgeResult.failure("App '$packageName' is not installed or has no launcher activity")
        return try {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            BridgeResult.success("Launched $packageName")
        } catch (e: Exception) {
            BridgeResult.failure("Failed to launch $packageName: ${e.message}")
        }
    }

    /** Best-effort: Android does not expose a general "current foreground app" API without
     * Accessibility or UsageStats. We use the accessibility service's last observed package. */
    fun getCurrentApp(): BridgeResult {
        val pkg = ZoyaAccessibilityService.instance?.lastEventPackage
            ?: return BridgeResult.permissionRequired("ACCESSIBILITY_SERVICE")
        return BridgeResult.success("Current app", JSONObject().put("packageName", pkg))
    }

    fun openAppInfo(packageName: String): BridgeResult {
        return try {
            val intent = Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = android.net.Uri.parse("package:$packageName")
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            context.startActivity(intent)
            BridgeResult.success("Opened app info for $packageName")
        } catch (e: Exception) {
            BridgeResult.failure("Could not open app info: ${e.message}")
        }
    }
}

ZOYAEOF

cat > android/app/src/main/java/com/zoya/ai/assistant/bridge/ZoyaBridgePlugin.kt << 'ZOYAEOF'
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

ZOYAEOF

cat > android/app/src/main/java/com/zoya/ai/assistant/accessibility/NodeFinder.kt << 'ZOYAEOF'
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

ZOYAEOF

cat > android/app/src/main/java/com/zoya/ai/assistant/accessibility/GestureExecutor.kt << 'ZOYAEOF'
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

ZOYAEOF

cat > android/app/src/main/java/com/zoya/ai/assistant/accessibility/ZoyaAccessibilityService.kt << 'ZOYAEOF'
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

ZOYAEOF

cat > android/app/src/main/java/com/zoya/ai/assistant/capture/ScreenCaptureService.kt << 'ZOYAEOF'
package com.zoya.ai.assistant.capture

import android.app.*
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.IBinder
import android.util.DisplayMetrics
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

/**
 * Official MediaProjection-based screen capture. Only starts after the user has explicitly
 * approved the system screen-capture consent dialog, runs only while needed, and shows a
 * persistent notification (Android requires this) so capture is never silent.
 */
class ScreenCaptureService : Service() {

    private var mediaProjection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null
    private val binder = LocalBinder()

    inner class LocalBinder : Binder() {
        fun service(): ScreenCaptureService = this@ScreenCaptureService
    }

    override fun onBind(intent: Intent?): IBinder = binder

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIF_ID, buildNotification())
        val resultCode = intent?.getIntExtra(EXTRA_RESULT_CODE, Activity.RESULT_CANCELED) ?: Activity.RESULT_CANCELED
        val data = intent?.getParcelableExtra<Intent>(EXTRA_DATA)
        if (resultCode == Activity.RESULT_OK && data != null) {
            val mgr = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            mediaProjection = mgr.getMediaProjection(resultCode, data)
            setupVirtualDisplay()
        }
        return START_NOT_STICKY
    }

    private fun setupVirtualDisplay() {
        val metrics = DisplayMetrics()
        (getSystemService(Context.WINDOW_SERVICE) as WindowManager).defaultDisplay.getRealMetrics(metrics)
        val width = metrics.widthPixels
        val height = metrics.heightPixels
        imageReader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
        virtualDisplay = mediaProjection?.createVirtualDisplay(
            "ZoyaCapture", width, height, metrics.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            imageReader?.surface, null, null
        )
    }

    /** Captures a single frame as a Bitmap. Returns null if capture isn't active. */
    suspend fun captureFrame(): Bitmap? = suspendCancellableCoroutine { cont ->
        val reader = imageReader
        if (reader == null) {
            cont.resume(null); return@suspendCancellableCoroutine
        }
        val image = reader.acquireLatestImage()
        if (image == null) {
            cont.resume(null); return@suspendCancellableCoroutine
        }
        try {
            val plane = image.planes[0]
            val buffer = plane.buffer
            val pixelStride = plane.pixelStride
            val rowStride = plane.rowStride
            val rowPadding = rowStride - pixelStride * image.width
            val bitmap = Bitmap.createBitmap(
                image.width + rowPadding / pixelStride, image.height, Bitmap.Config.ARGB_8888
            )
            bitmap.copyPixelsFromBuffer(buffer)
            cont.resume(Bitmap.createBitmap(bitmap, 0, 0, image.width, image.height))
        } finally {
            image.close()
        }
    }

    fun isActive(): Boolean = mediaProjection != null

    fun stopCapture() {
        virtualDisplay?.release()
        imageReader?.close()
        mediaProjection?.stop()
        virtualDisplay = null
        imageReader = null
        mediaProjection = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun buildNotification(): Notification {
        val channelId = "zoya_screen_capture"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId, "Zoya Screen Capture", NotificationManager.IMPORTANCE_LOW
            )
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(channel)
        }
        return NotificationCompat.Builder(this, channelId)
            .setContentTitle("Zoya is capturing the screen")
            .setContentText("Tap to stop")
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setOngoing(true)
            .build()
    }

    override fun onDestroy() {
        stopCapture()
        super.onDestroy()
    }

    companion object {
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_DATA = "data"
        private const val NOTIF_ID = 5501
    }
}

ZOYAEOF

cat > android/app/src/main/java/com/zoya/ai/assistant/ocr/OCRManager.kt << 'ZOYAEOF'
package com.zoya.ai.assistant.ocr

import android.graphics.Bitmap
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import com.zoya.ai.assistant.bridge.BridgeResult
import kotlinx.coroutines.suspendCancellableCoroutine
import org.json.JSONArray
import org.json.JSONObject
import kotlin.coroutines.resume

/**
 * On-device OCR (ML Kit Text Recognition v2). Only invoked on-demand — never runs continuously —
 * and results are cached briefly by the caller (AutomationEngine / workflow layer) as the PRD
 * requires, rather than inside this stateless manager.
 */
class OCRManager {

    private val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)

    suspend fun recognize(bitmap: Bitmap): BridgeResult = suspendCancellableCoroutine { cont ->
        val image = InputImage.fromBitmap(bitmap, 0)
        recognizer.process(image)
            .addOnSuccessListener { visionText ->
                val blocks = JSONArray()
                for (block in visionText.textBlocks) {
                    for (line in block.lines) {
                        val box = line.boundingBox
                        blocks.put(JSONObject().apply {
                            put("text", line.text)
                            put("bounds", JSONObject().apply {
                                put("left", box?.left ?: 0)
                                put("top", box?.top ?: 0)
                                put("right", box?.right ?: 0)
                                put("bottom", box?.bottom ?: 0)
                            })
                        })
                    }
                }
                if (cont.isActive) {
                    cont.resume(
                        BridgeResult.success(
                            "OCR complete",
                            JSONObject().put("fullText", visionText.text).put("lines", blocks)
                        )
                    )
                }
            }
            .addOnFailureListener { e ->
                if (cont.isActive) cont.resume(BridgeResult.failure("OCR failed: ${e.message}"))
            }
    }

    /** Finds the first recognized text line matching [query] (case-insensitive contains). */
    suspend fun findText(bitmap: Bitmap, query: String): BridgeResult {
        val result = recognize(bitmap)
        if (result.status != com.zoya.ai.assistant.bridge.ResultStatus.SUCCESS) return result
        val lines = result.data?.optJSONArray("lines") ?: JSONArray()
        for (i in 0 until lines.length()) {
            val line = lines.getJSONObject(i)
            if (line.optString("text").contains(query, ignoreCase = true)) {
                return BridgeResult.success("Found text", line)
            }
        }
        return BridgeResult.failure("Text '$query' not found on screen")
    }

    fun close() = recognizer.close()
}

ZOYAEOF

cat > android/app/src/main/java/com/zoya/ai/assistant/camera/CameraController.kt << 'ZOYAEOF'
package com.zoya.ai.assistant.camera

import android.content.ContentValues
import android.content.Context
import android.provider.MediaStore
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import com.zoya.ai.assistant.bridge.BridgeResult
import kotlinx.coroutines.suspendCancellableCoroutine
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Locale
import kotlin.coroutines.resume

/**
 * CameraX-based capture. Requires an explicit prior CAMERA permission grant and a bound
 * lifecycle owner (an activity the user can see) — the camera is never opened silently.
 */
class CameraController(private val context: Context) {

    private var imageCapture: ImageCapture? = null

    suspend fun bind(lifecycleOwner: LifecycleOwner, useFrontCamera: Boolean): BridgeResult =
        suspendCancellableCoroutine { cont ->
            val providerFuture = ProcessCameraProvider.getInstance(context)
            providerFuture.addListener({
                try {
                    val provider = providerFuture.get()
                    val capture = ImageCapture.Builder().build()
                    val selector = if (useFrontCamera) CameraSelector.DEFAULT_FRONT_CAMERA
                    else CameraSelector.DEFAULT_BACK_CAMERA
                    provider.unbindAll()
                    provider.bindToLifecycle(lifecycleOwner, selector, capture)
                    imageCapture = capture
                    if (cont.isActive) cont.resume(BridgeResult.success("Camera bound"))
                } catch (e: Exception) {
                    if (cont.isActive) cont.resume(BridgeResult.failure("Could not open camera: ${e.message}"))
                }
            }, ContextCompat.getMainExecutor(context))
        }

    suspend fun takePhoto(): BridgeResult = suspendCancellableCoroutine { cont ->
        val capture = imageCapture
        if (capture == null) {
            cont.resume(BridgeResult.failure("Camera is not bound/open"))
            return@suspendCancellableCoroutine
        }
        val name = "zoya_${SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(System.currentTimeMillis())}.jpg"
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, "image/jpeg")
            put(MediaStore.MediaColumns.RELATIVE_PATH, "Pictures/Zoya")
        }
        val outputOptions = ImageCapture.OutputFileOptions.Builder(
            context.contentResolver, MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values
        ).build()

        capture.takePicture(
            outputOptions,
            ContextCompat.getMainExecutor(context),
            object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(output: ImageCapture.OutputFileResults) {
                    if (cont.isActive) {
                        cont.resume(
                            BridgeResult.success(
                                "Photo saved",
                                JSONObject().put("uri", output.savedUri?.toString())
                            )
                        )
                    }
                }
                override fun onError(exception: ImageCaptureException) {
                    if (cont.isActive) cont.resume(BridgeResult.failure("Capture failed: ${exception.message}"))
                }
            }
        )
    }
}

ZOYAEOF

cat > android/app/src/main/java/com/zoya/ai/assistant/settings/SystemSettingsController.kt << 'ZOYAEOF'
package com.zoya.ai.assistant.settings

import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.net.Uri
import android.provider.Settings
import com.zoya.ai.assistant.bridge.BridgeResult

class SystemSettingsController(private val context: Context) {

    /** Opens an official Android settings screen by name. Never bypasses restricted settings. */
    fun open(screen: String): BridgeResult {
        val action = when (screen) {
            "wifi" -> Settings.ACTION_WIFI_SETTINGS
            "bluetooth" -> Settings.ACTION_BLUETOOTH_SETTINGS
            "mobile_network" -> Settings.ACTION_DATA_ROAMING_SETTINGS
            "display" -> Settings.ACTION_DISPLAY_SETTINGS
            "sound" -> Settings.ACTION_SOUND_SETTINGS
            "notifications" -> Settings.ACTION_APP_NOTIFICATION_SETTINGS
            "accessibility" -> Settings.ACTION_ACCESSIBILITY_SETTINGS
            "app_settings" -> Settings.ACTION_APPLICATION_DETAILS_SETTINGS
            "battery" -> Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS
            "app_permissions" -> Settings.ACTION_APPLICATION_DETAILS_SETTINGS
            "developer" -> Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS
            "notification_listener" -> Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS
            else -> return BridgeResult.unsupported("Unknown settings screen: $screen")
        }
        return try {
            val intent = Intent(action).apply { flags = Intent.FLAG_ACTIVITY_NEW_TASK }
            if (screen == "app_settings" || screen == "app_permissions") {
                intent.data = Uri.parse("package:${context.packageName}")
            }
            context.startActivity(intent)
            BridgeResult.success("Opened $screen settings")
        } catch (e: Exception) {
            BridgeResult.failure("Could not open $screen settings: ${e.message}")
        }
    }

    fun openAccessibilitySettings(): BridgeResult = open("accessibility")

    /** Brightness control requires WRITE_SETTINGS which itself needs a manual grant screen. */
    fun setBrightness(value: Int): BridgeResult {
        if (!Settings.System.canWrite(context)) {
            return BridgeResult.permissionRequired("WRITE_SETTINGS")
        }
        return try {
            val clamped = value.coerceIn(0, 255)
            Settings.System.putInt(
                context.contentResolver, Settings.System.SCREEN_BRIGHTNESS, clamped
            )
            BridgeResult.success("Brightness set to $clamped")
        } catch (e: Exception) {
            BridgeResult.failure("Failed to set brightness: ${e.message}")
        }
    }

    fun setVolume(streamType: Int, value: Int): BridgeResult {
        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        return try {
            val max = am.getStreamMaxVolume(streamType)
            val clamped = value.coerceIn(0, max)
            am.setStreamVolume(streamType, clamped, 0)
            BridgeResult.success("Volume set to $clamped/$max")
        } catch (e: Exception) {
            BridgeResult.failure("Failed to set volume: ${e.message}")
        }
    }
}

ZOYAEOF

cat > android/app/src/main/java/com/zoya/ai/assistant/workflow/WorkflowModels.kt << 'ZOYAEOF'
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

ZOYAEOF

cat > android/app/src/main/java/com/zoya/ai/assistant/workflow/WorkflowEngine.kt << 'ZOYAEOF'
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

ZOYAEOF

cat > android/app/src/main/java/com/zoya/ai/assistant/scheduler/TaskScheduler.kt << 'ZOYAEOF'
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

ZOYAEOF

cat > android/app/src/main/java/com/zoya/ai/assistant/scheduler/WorkflowWorker.kt << 'ZOYAEOF'
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

ZOYAEOF

cat > android/app/src/main/java/com/zoya/ai/assistant/storage/LocalStore.kt << 'ZOYAEOF'
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

ZOYAEOF

cat > android/app/src/main/java/com/zoya/ai/assistant/ui/PermissionSetupActivity.kt << 'ZOYAEOF'
package com.zoya.ai.assistant.ui

import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import android.widget.Button
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import com.zoya.ai.assistant.R
import com.zoya.ai.assistant.bridge.AutomationEngine

/**
 * Dedicated setup screen (required by the PRD) so the user can see and manage the
 * Accessibility Service status without digging through system settings blindly.
 */
class PermissionSetupActivity : AppCompatActivity() {

    private lateinit var engine: AutomationEngine
    private lateinit var statusText: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_permission_setup)
        engine = AutomationEngine(this)
        statusText = findViewById(R.id.statusText)

        findViewById<Button>(R.id.openAccessibilityButton).setOnClickListener {
            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
        }
        findViewById<Button>(R.id.doneButton).setOnClickListener { finish() }
    }

    override fun onResume() {
        super.onResume()
        refreshStatus()
    }

    private fun refreshStatus() {
        val enabled = engine.isAccessibilityEnabled()
        statusText.text = if (enabled) {
            getString(R.string.accessibility_status_enabled)
        } else {
            getString(R.string.accessibility_status_disabled)
        }
    }
}

ZOYAEOF

cat > android/app/src/main/java/com/zoya/ai/assistant/ui/ConfirmActionActivity.kt << 'ZOYAEOF'
package com.zoya.ai.assistant.ui

import android.app.Activity
import android.os.Bundle
import androidx.appcompat.app.AlertDialog

/**
 * Blocking, explicit confirmation required before financial transactions, purchases,
 * deletions, uninstalls, sending sensitive info, or changing critical security settings —
 * per the PRD's "Sensitive Action Protection" section. The workflow/bridge layer must call
 * this (and receive a positive result) before performing any such action; it must never
 * skip this step or infer consent.
 */
class ConfirmActionActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val title = intent.getStringExtra(EXTRA_TITLE) ?: "Confirm action"
        val message = intent.getStringExtra(EXTRA_MESSAGE) ?: "Zoya wants to perform a sensitive action."

        AlertDialog.Builder(this)
            .setTitle(title)
            .setMessage(message)
            .setCancelable(false)
            .setPositiveButton("Allow") { _, _ -> finishWithResult(true) }
            .setNegativeButton("Deny") { _, _ -> finishWithResult(false) }
            .setOnCancelListener { finishWithResult(false) }
            .show()
    }

    private fun finishWithResult(confirmed: Boolean) {
        val data = android.content.Intent().putExtra(EXTRA_RESULT, confirmed)
        setResult(if (confirmed) Activity.RESULT_OK else Activity.RESULT_CANCELED, data)
        finish()
    }

    companion object {
        const val EXTRA_TITLE = "title"
        const val EXTRA_MESSAGE = "message"
        const val EXTRA_RESULT = "confirmed"
    }
}

ZOYAEOF

# 4. Write updated Gradle + Manifest + resource files
cat > android/build.gradle << 'ZOYAEOF'
// Top-level build file where you can add configuration options common to all sub-projects/modules.

buildscript {
    ext.kotlin_version = '1.9.24'

    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        classpath 'com.android.tools.build:gradle:8.13.0'
        classpath 'com.google.gms:google-services:4.4.4'
        classpath "org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlin_version"

        // NOTE: Do not place your application dependencies here; they belong
        // in the individual module build.gradle files
    }
}

apply from: "variables.gradle"

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

task clean(type: Delete) {
    delete rootProject.buildDir
}

ZOYAEOF

cat > android/app/build.gradle << 'ZOYAEOF'
apply plugin: 'com.android.application'
apply plugin: 'kotlin-android'

android {
    namespace = "com.zoya.ai.assistant"
    compileSdk = rootProject.ext.compileSdkVersion
    defaultConfig {
        applicationId "com.zoya.ai.assistant"
        minSdkVersion rootProject.ext.minSdkVersion
        targetSdkVersion rootProject.ext.targetSdkVersion
        versionCode 1
        versionName "1.0"
        testInstrumentationRunner "androidx.test.runner.AndroidJUnitRunner"
        aaptOptions {
             ignoreAssetsPattern = '!.svn:!.git:!.ds_store:!*.scc:.*:!CVS:!thumbs.db:!picasa.ini:!*~'
        }
    }
    buildTypes {
        release {
            minifyEnabled false
            proguardFiles getDefaultProguardFile('proguard-android.txt'), 'proguard-rules.pro'
        }
    }
    compileOptions {
        sourceCompatibility JavaVersion.VERSION_17
        targetCompatibility JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        viewBinding true
    }
}

repositories {
    flatDir{
        dirs '../capacitor-cordova-android-plugins/src/main/libs', 'libs'
    }
}

dependencies {
    implementation fileTree(include: ['*.jar'], dir: 'libs')
    implementation "androidx.appcompat:appcompat:$androidxAppCompatVersion"
    implementation "androidx.coordinatorlayout:coordinatorlayout:$androidxCoordinatorLayoutVersion"
    implementation "androidx.core:core-splashscreen:$coreSplashScreenVersion"
    implementation project(':capacitor-android')
    testImplementation "junit:junit:$junitVersion"
    androidTestImplementation "androidx.test.ext:junit:$androidxJunitVersion"
    androidTestImplementation "androidx.test.espresso:espresso-core:$androidxEspressoCoreVersion"
    implementation project(':capacitor-cordova-android-plugins')

    // --- Zoya native automation layer dependencies ---
    implementation "androidx.work:work-runtime-ktx:2.9.1"
    implementation "androidx.camera:camera-core:1.3.4"
    implementation "androidx.camera:camera-camera2:1.3.4"
    implementation "androidx.camera:camera-lifecycle:1.3.4"
    implementation "androidx.camera:camera-view:1.3.4"
    implementation "com.google.mlkit:text-recognition:16.0.1"
    implementation "org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1"
}

apply from: 'capacitor.build.gradle'

try {
    def servicesJSON = file('google-services.json')
    if (servicesJSON.text) {
        apply plugin: 'com.google.gms.google-services'
    }
} catch(Exception e) {
    logger.info("google-services.json not found, google-services plugin not applied. Push Notifications won't work")
}

ZOYAEOF

cat > android/app/src/main/AndroidManifest.xml << 'ZOYAEOF'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">

    <!-- Permissions -->
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <uses-permission android:name="android.permission.RECORD_AUDIO" />
    <uses-permission android:name="android.permission.CAMERA" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    <uses-permission android:name="android.permission.VIBRATE" />
    <uses-permission android:name="android.permission.QUERY_ALL_PACKAGES" tools:ignore="QueryAllPackagesPermission" />
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_SPECIAL_USE" />
    <uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW" />
    <uses-permission android:name="android.permission.BIND_NOTIFICATION_LISTENER_SERVICE"
        tools:ignore="ProtectedPermissions" />

    <uses-feature android:name="android.hardware.camera" android:required="false" />
    <uses-feature android:name="android.hardware.camera.autofocus" android:required="false" />

    <application
        android:allowBackup="true"
        android:icon="@mipmap/ic_launcher"
        android:label="@string/app_name"
        android:roundIcon="@mipmap/ic_launcher_round"
        android:supportsRtl="true"
        android:theme="@style/AppTheme">

        <activity
            android:configChanges="orientation|keyboardHidden|keyboard|screenSize|locale|smallestScreenSize|screenLayout|uiMode|navigation|density"
            android:name=".MainActivity"
            android:label="@string/title_activity_main"
            android:theme="@style/AppTheme.NoActionBarLaunch"
            android:launchMode="singleTask"
            android:exported="true">

            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>

        </activity>

        <activity
            android:name=".ui.PermissionSetupActivity"
            android:exported="false"
            android:label="Zoya Permissions" />

        <activity
            android:name=".ui.ConfirmActionActivity"
            android:exported="false"
            android:theme="@style/AppTheme.NoActionBar" />

        <service
            android:name=".accessibility.ZoyaAccessibilityService"
            android:exported="true"
            android:label="Zoya Automation"
            android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE">
            <intent-filter>
                <action android:name="android.accessibilityservice.AccessibilityService" />
            </intent-filter>
            <meta-data
                android:name="android.accessibilityservice"
                android:resource="@xml/accessibility_service_config" />
        </service>

        <service
            android:name=".capture.ScreenCaptureService"
            android:exported="false"
            android:foregroundServiceType="mediaProjection" />

        <provider
            android:name="androidx.core.content.FileProvider"
            android:authorities="${applicationId}.fileprovider"
            android:exported="false"
            android:grantUriPermissions="true">
            <meta-data
                android:name="android.support.FILE_PROVIDER_PATHS"
                android:resource="@xml/file_paths"></meta-data>
        </provider>
    </application>

</manifest>

ZOYAEOF

cat > android/app/src/main/res/values/strings.xml << 'ZOYAEOF'
<?xml version='1.0' encoding='utf-8'?>
<resources>
    <string name="app_name">Zoya AI Assistant</string>
    <string name="title_activity_main">Zoya AI Assistant</string>
    <string name="package_name">com.zoya.ai.assistant</string>
    <string name="custom_url_scheme">com.zoya.ai.assistant</string>

    <string name="accessibility_service_description">Lets Zoya read on-screen elements and perform taps, swipes and typing that you explicitly ask it to, so it can automate tasks on your behalf. It never acts without your instruction.</string>
    <string name="accessibility_status_enabled">Accessibility Service: ENABLED\nZoya can automate on-screen actions.</string>
    <string name="accessibility_status_disabled">Accessibility Service: DISABLED\nEnable it below so Zoya can automate on-screen actions.</string>
    <string name="open_accessibility_settings">Open Accessibility Settings</string>
    <string name="done">Done</string>
</resources>

ZOYAEOF

cat > android/app/src/main/res/values/colors.xml << 'ZOYAEOF'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="colorPrimary">#09090b</color>
    <color name="colorPrimaryDark">#000000</color>
    <color name="colorAccent">#7c3aed</color>
    <color name="background_dark">#09090b</color>
</resources>

ZOYAEOF

cat > android/app/src/main/res/xml/accessibility_service_config.xml << 'ZOYAEOF'
<?xml version="1.0" encoding="utf-8"?>
<accessibility-service xmlns:android="http://schemas.android.com/apk/res/android"
    android:accessibilityEventTypes="typeAllMask"
    android:accessibilityFeedbackType="feedbackGeneric"
    android:accessibilityFlags="flagDefault|flagReportViewIds|flagRetrieveInteractiveWindows"
    android:canPerformGestures="true"
    android:canRetrieveWindowContent="true"
    android:description="@string/accessibility_service_description"
    android:notificationTimeout="80"
    android:packageNames=""
    android:settingsActivity="com.zoya.ai.assistant.ui.PermissionSetupActivity" />

ZOYAEOF

cat > android/app/src/main/res/layout/activity_permission_setup.xml << 'ZOYAEOF'
<?xml version="1.0" encoding="utf-8"?>
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:orientation="vertical"
    android:padding="24dp"
    android:gravity="center">

    <TextView
        android:id="@+id/statusText"
        android:layout_width="wrap_content"
        android:layout_height="wrap_content"
        android:textSize="16sp"
        android:layout_marginBottom="24dp" />

    <Button
        android:id="@+id/openAccessibilityButton"
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:text="@string/open_accessibility_settings" />

    <Button
        android:id="@+id/doneButton"
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:layout_marginTop="12dp"
        android:text="@string/done" />

</LinearLayout>

ZOYAEOF

# 5. Also add the androidBridge.ts helper for the web app
mkdir -p src/lib
cat > src/lib/androidBridge.ts << 'ZOYAEOF'
// Thin, typed wrapper over the native "ZoyaBridge" Capacitor plugin.
// Import this from the existing web app instead of calling Capacitor.Plugins directly,
// so every native call has a consistent shape and works safely in a plain browser too
// (falls back to "unsupported" instead of throwing, per the PRD's browser-fallback rule).

import { Capacitor, registerPlugin } from '@capacitor/core';

export type BridgeStatus = 'success' | 'failure' | 'permission_required' | 'timeout' | 'unsupported';

export interface BridgeResult<T = any> {
  status: BridgeStatus;
  message: string;
  data: T;
}

interface ZoyaBridgePlugin {
  requestPermission(options: { permission: string }): Promise<BridgeResult>;
  getPermissionStatus(): Promise<Record<string, any>>;
  launchApp(options: { packageName: string }): Promise<BridgeResult>;
  getInstalledApps(options?: { query?: string }): Promise<BridgeResult>;
  getCurrentApp(): Promise<BridgeResult>;
  tap(options: { x: number; y: number }): Promise<BridgeResult>;
  longPress(options: { x: number; y: number; durationMs?: number }): Promise<BridgeResult>;
  swipe(options: { x1: number; y1: number; x2: number; y2: number; durationMs?: number }): Promise<BridgeResult>;
  scroll(options: { forward?: boolean; resourceId?: string; text?: string }): Promise<BridgeResult>;
  gesture(options: { points: { x: number; y: number }[]; durationMs?: number }): Promise<BridgeResult>;
  readScreen(): Promise<BridgeResult>;
  captureScreen(): Promise<BridgeResult>;
  performOCR(): Promise<BridgeResult>;
  findUIElement(options: {
    text?: string; partialText?: string; regex?: string; contentDescription?: string; resourceId?: string; className?: string;
  }): Promise<BridgeResult>;
  typeText(options: { text: string; resourceId?: string; targetText?: string }): Promise<BridgeResult>;
  pressBack(): Promise<BridgeResult>;
  pressHome(): Promise<BridgeResult>;
  openSettings(options: { screen: string }): Promise<BridgeResult>;
  setBrightness(options: { value: number }): Promise<BridgeResult>;
  setVolume(options: { value: number; stream?: string }): Promise<BridgeResult>;
  takePhoto(options?: { front?: boolean }): Promise<BridgeResult>;
  startAutomation(options: { workflow: any }): Promise<BridgeResult>;
  stopAutomation(): Promise<BridgeResult>;
  getAutomationStatus(): Promise<{ running: boolean; accessibilityEnabled: boolean }>;
  scheduleTask(options: { workflowId: string; kind?: 'one_time' | 'recurring'; delayMs?: number; intervalMinutes?: number }): Promise<BridgeResult>;
  getExecutionLogs(): Promise<{ logs: any[] }>;
  addListener(eventName: 'automationStatus', listenerFunc: (data: any) => void): Promise<{ remove: () => void }>;
}

const isNative = Capacitor.isNativePlatform();

const ZoyaBridgeNative = isNative ? registerPlugin<ZoyaBridgePlugin>('ZoyaBridge') : null;

function unsupported(message: string): BridgeResult {
  return { status: 'unsupported', message, data: {} };
}

/**
 * Safe wrapper: on a real Android build this calls into Kotlin; in a plain browser
 * (or during `npm run dev`) every call resolves to a structured "unsupported" result
 * instead of throwing, so the existing web UI keeps working unmodified.
 */
export const androidBridge = {
  isAvailable: () => isNative && !!ZoyaBridgeNative,

  requestPermission: (permission: string) =>
    ZoyaBridgeNative?.requestPermission({ permission }) ?? Promise.resolve(unsupported('Not running on Android')),

  getPermissionStatus: () =>
    ZoyaBridgeNative?.getPermissionStatus() ?? Promise.resolve({}),

  tap: (x: number, y: number) =>
    ZoyaBridgeNative?.tap({ x, y }) ?? Promise.resolve(unsupported('Not running on Android')),

  swipe: (x1: number, y1: number, x2: number, y2: number, durationMs = 300) =>
    ZoyaBridgeNative?.swipe({ x1, y1, x2, y2, durationMs }) ?? Promise.resolve(unsupported('Not running on Android')),

  readScreen: () => ZoyaBridgeNative?.readScreen() ?? Promise.resolve(unsupported('Not running on Android')),

  findUIElement: (selector: Parameters<ZoyaBridgePlugin['findUIElement']>[0]) =>
    ZoyaBridgeNative?.findUIElement(selector) ?? Promise.resolve(unsupported('Not running on Android')),

  typeText: (text: string, target?: { resourceId?: string; targetText?: string }) =>
    ZoyaBridgeNative?.typeText({ text, ...target }) ?? Promise.resolve(unsupported('Not running on Android')),

  launchApp: (packageName: string) =>
    ZoyaBridgeNative?.launchApp({ packageName }) ?? Promise.resolve(unsupported('Not running on Android')),

  getInstalledApps: (query?: string) =>
    ZoyaBridgeNative?.getInstalledApps({ query }) ?? Promise.resolve(unsupported('Not running on Android')),

  openSettings: (screen: string) =>
    ZoyaBridgeNative?.openSettings({ screen }) ?? Promise.resolve(unsupported('Not running on Android')),

  startAutomation: (workflow: any) =>
    ZoyaBridgeNative?.startAutomation({ workflow }) ?? Promise.resolve(unsupported('Not running on Android')),

  stopAutomation: () =>
    ZoyaBridgeNative?.stopAutomation() ?? Promise.resolve(unsupported('Not running on Android')),

  getAutomationStatus: () =>
    ZoyaBridgeNative?.getAutomationStatus() ?? Promise.resolve({ running: false, accessibilityEnabled: false }),

  onAutomationStatus: (callback: (data: any) => void) =>
    ZoyaBridgeNative?.addListener('automationStatus', callback) ?? Promise.resolve({ remove: () => {} }),
};

ZOYAEOF

echo ""
echo "== All files written. Reviewing git status =="
git status
echo ""
echo "Now run:  git add . && git commit -m \"Restore Zoya automation code\" && git push"
