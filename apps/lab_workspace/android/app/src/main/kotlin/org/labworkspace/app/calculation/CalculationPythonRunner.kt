package org.labworkspace.app.calculation

import android.content.Context
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import org.json.JSONObject

/** Narrow host for the bundled, trusted calculation JSON-RPC module. */
object CalculationPythonRunner {
    private const val MODULE_NAME = "mobile.calculation_mobile_bridge"
    private const val MAX_REQUEST_CHARS = 32 * 1024 * 1024

    fun probe(context: Context): String {
        val request = """{"jsonrpc":"2.0","id":"probe","method":"probe","params":{}}"""
        return try {
            val response = handleJsonRpc(context, request)
            if (!JSONObject(response).has("error")) response else unavailableProbe()
        } catch (_: Throwable) {
            unavailableProbe()
        }
    }

    private fun unavailableProbe(): String = JSONObject()
        .put("jsonrpc", "2.0")
        .put("id", "probe")
        .put(
            "result",
            JSONObject()
                .put("executor_id", "trusted-python-mobile-v2")
                .put("platform", "android")
                .put("available", false)
                .put("bundled_executor", false)
                .put("python_runtime", "unavailable")
                .put("supported_operations", emptyArray<String>())
                .put("supports_cancellation", false)
                .put("unsupported_reason", "TRUSTED_PYTHON_RUNTIME_UNAVAILABLE"),
        )
        .toString()

    /**
     * Accepts only a complete typed JSON-RPC request. The Python entry point
     * performs allowlist, approval, hash, Decimal, and ROI validation.
     */
    fun handleJsonRpc(context: Context, requestJson: String): String {
        require(requestJson.length <= MAX_REQUEST_CHARS) {
            "Calculation JSON-RPC request exceeds the 32 MiB limit."
        }
        try {
            if (!Python.isStarted()) {
                Python.start(AndroidPlatform(context.applicationContext))
            }
            val module = Python.getInstance().getModule(MODULE_NAME)
            return module.callAttr("handle_json", requestJson, "android").toJava(String::class.java)
                ?: throw IllegalStateException("Trusted Python runtime returned no JSON response.")
        } catch (_: Throwable) {
            return JSONObject()
                .put("jsonrpc", "2.0")
                .put("id", JSONObject.NULL)
                .put(
                    "error",
                    JSONObject()
                        .put("code", -32010)
                        .put("message", "TRUSTED_PYTHON_RUNTIME_UNAVAILABLE"),
                )
                .toString()
        }
    }
}\n
