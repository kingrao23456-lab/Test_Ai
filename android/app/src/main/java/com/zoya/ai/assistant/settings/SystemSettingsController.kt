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

