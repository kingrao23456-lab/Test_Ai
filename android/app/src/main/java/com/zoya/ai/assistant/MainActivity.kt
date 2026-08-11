package com.zoya.ai.assistant

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import com.getcapacitor.BridgeActivity
import com.zoya.ai.assistant.bridge.ZoyaBridgePlugin
import com.zoya.ai.assistant.capture.ScreenCaptureService

class MainActivity : BridgeActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // Register our custom native plugin BEFORE super.onCreate()
        registerPlugin(ZoyaBridgePlugin::class.java)
        super.onCreate(savedInstanceState)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == ZoyaBridgePlugin.SCREEN_CAPTURE_REQUEST) {
            if (resultCode == Activity.RESULT_OK && data != null) {
                val serviceIntent = Intent(this, ScreenCaptureService::class.java).apply {
                    putExtra(ScreenCaptureService.EXTRA_RESULT_CODE, resultCode)
                    putExtra(ScreenCaptureService.EXTRA_DATA, data)
                }
                startForegroundService(serviceIntent)
            }
            // If the user denied the consent dialog, we deliberately do nothing further —
            // the next captureScreen()/performOCR() call will report failure/unsupported
            // rather than silently pretending capture is active.
        }
    }
}
