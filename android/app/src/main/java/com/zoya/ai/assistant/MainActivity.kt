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

