package com.zoya.ai.assistant

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.webkit.PermissionRequest
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.getcapacitor.BridgeActivity
import com.getcapacitor.BridgeWebChromeClient
import com.zoya.ai.assistant.bridge.ZoyaBridgePlugin
import com.zoya.ai.assistant.capture.ScreenCaptureService

class MainActivity : BridgeActivity() {

    private var pendingWebRequest: PermissionRequest? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        registerPlugin(ZoyaBridgePlugin::class.java)
        super.onCreate(savedInstanceState)

        bridge.webView.webChromeClient = object : BridgeWebChromeClient(bridge) {
            override fun onPermissionRequest(request: PermissionRequest) {
                runOnUiThread { handleWebPermissionRequest(request) }
            }
        }

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                this, arrayOf(Manifest.permission.RECORD_AUDIO), MIC_PERMISSION_CODE
            )
        }
    }

    private fun handleWebPermissionRequest(request: PermissionRequest) {
        val needsMic = request.resources.contains(PermissionRequest.RESOURCE_AUDIO_CAPTURE)
        val micGranted = ContextCompat.checkSelfPermission(
            this, Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED

        if (needsMic && !micGranted) {
            pendingWebRequest = request
            ActivityCompat.requestPermissions(
                this, arrayOf(Manifest.permission.RECORD_AUDIO), MIC_PERMISSION_CODE
            )
        } else {
            request.grant(request.resources)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == MIC_PERMISSION_CODE) {
            val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingWebRequest?.let { req ->
                if (granted) req.grant(req.resources) else req.deny()
            }
            pendingWebRequest = null
        }
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
        }
    }

    companion object {
        private const val MIC_PERMISSION_CODE = 5501
    }
}
