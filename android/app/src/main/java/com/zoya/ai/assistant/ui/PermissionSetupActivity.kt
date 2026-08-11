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
