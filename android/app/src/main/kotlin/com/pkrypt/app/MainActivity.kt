package com.pkrypt.app

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity : FlutterFragmentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        PkryptApplication.getOrCreateEngine(applicationContext)
        super.onCreate(savedInstanceState)
        PkryptApplication.setActiveActivity(this)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    override fun getCachedEngineId(): String = PkryptApplication.ENGINE_ID

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onDestroy() {
        PkryptApplication.clearActiveActivity(this)
        super.onDestroy()
    }
}