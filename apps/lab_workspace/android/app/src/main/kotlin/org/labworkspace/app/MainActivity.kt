package org.labworkspace.app

import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import org.labworkspace.app.calculation.CalculationPythonRunner

class MainActivity : FlutterActivity() {
    private val channelName = "lab_workspace/native_files"
    private val calculationExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                val arguments = call.arguments as? Map<*, *>
                val rawPath = arguments?.get("path") as? String
                val file = rawPath?.let(::authorizedTemporaryFile)
                if (file == null) {
                    result.error("FILE_PATH_DENIED", "The selected path is outside app temporary storage.", null)
                    return@setMethodCallHandler
                }
                val mimeType = arguments?.get("mimeType") as? String ?: "application/octet-stream"
                when (call.method) {
                    "openFile" -> openFile(file, mimeType, result)
                    "shareFile" -> shareFile(file, mimeType, result)
                    "revealFile" -> result.success(false)
                    else -> result.notImplemented()
                }
            }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "lab_workspace/calculation_executor",
        ).setMethodCallHandler { call, result ->
            val requestJson = (call.arguments as? Map<*, *>)?.get("requestJson") as? String
            if (requestJson == null || requestJson.length > 32 * 1024 * 1024) {
                result.error("INVALID_RPC_REQUEST", "A bounded JSON-RPC requestJson is required.", null)
                return@setMethodCallHandler
            }
            if (call.method !in setOf("probe", "execute", "requestCancel", "getLogs", "quantifyRoi")) {
                result.notImplemented()
                return@setMethodCallHandler
            }
            calculationExecutor.execute {
                val responseJson = try {
                    if (call.method == "probe") CalculationPythonRunner.probe(applicationContext)
                    else CalculationPythonRunner.handleJsonRpc(applicationContext, requestJson)
                } catch (_: Throwable) {
                    """{"jsonrpc":"2.0","id":null,"error":{"code":-32010,"message":"TRUSTED_PYTHON_RUNTIME_UNAVAILABLE"}}"""
                }
                mainHandler.post { result.success(responseJson) }
            }
        }
    }

    override fun onDestroy() {
        calculationExecutor.shutdown()
        super.onDestroy()
    }

    private fun authorizedTemporaryFile(path: String): File? {
        return try {
            val file = File(path).canonicalFile
            val cache = cacheDir.canonicalFile
            val allowed = File(cache, "lab_workspace_open").canonicalFile
            if (file.path.startsWith(allowed.path + File.separator) && file.isFile) file else null
        } catch (_: java.io.IOException) {
            null
        } catch (_: SecurityException) {
            null
        }
    }

    private fun contentUri(file: File): Uri = FileProvider.getUriForFile(
        this,
        "${BuildConfig.APPLICATION_ID}.files",
        file,
    )

    private fun openFile(file: File, mimeType: String, result: MethodChannel.Result) {
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(contentUri(file), mimeType)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            startActivity(intent)
            result.success(true)
        } catch (_: android.content.ActivityNotFoundException) {
            result.error("NO_FILE_VIEWER", "No installed app can open this file type.", null)
        }
    }

    private fun shareFile(file: File, mimeType: String, result: MethodChannel.Result) {
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = mimeType
            putExtra(Intent.EXTRA_STREAM, contentUri(file))
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            startActivity(Intent.createChooser(intent, "Share Lab Workspace file"))
            result.success(true)
        } catch (_: android.content.ActivityNotFoundException) {
            result.error("SHARE_UNAVAILABLE", "No app can share this file type.", null)
        }
    }
}
