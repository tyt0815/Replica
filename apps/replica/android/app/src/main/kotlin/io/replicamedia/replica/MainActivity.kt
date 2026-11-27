package io.replicamedia.replica

import io.flutter.embedding.android.FlutterActivity
import android.webkit.WebView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private var parser: WebView? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val bundle by lazy { assets.open("search.js").bufferedReader().use { it.readText() } }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "replica/search").setMethodCallHandler { call, result ->
            if (call.method != "parse") {
                result.notImplemented()
            } else {
                val runtime = parser ?: WebView(this).also {
                    it.settings.javaScriptEnabled = true
                    it.settings.blockNetworkLoads = true
                    parser = it
                }
                val payload = JSONObject.quote(call.arguments as String)
                runtime.evaluateJavascript(bundle + "\nReplicaSearch.videos(JSON.parse(" + payload + "))") {
                    if (it == null || it == "null") result.error("parse", "검색 결과를 읽을 수 없습니다.", null)
                    else result.success(it)
                }
            }
        }
    }

    override fun onDestroy() {
        parser?.destroy()
        super.onDestroy()
    }
}
