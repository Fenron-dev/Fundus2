package dev.fundus.fundus2

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import com.ryanheise.audioservice.AudioServiceFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The activity, with the one channel Android cannot do without.
 *
 * A Fundus library is a folder full of media that other tools also write to,
 * so the app needs to read it as files rather than through a document picker:
 * the scanner walks directories, the reader opens archives by path, and a
 * SAF tree URI is none of those things. On Android 11 and later that means
 * "All files access", which only the system settings can grant.
 *
 * It extends audio_service's activity so a media session can outlive the
 * window: an audiobook that stops the moment the app leaves the screen is
 * not an audiobook.
 *
 * The previous client's activity also carried a channel for opening files in
 * other apps and one for rendering PDF pages. The PDF one is gone for good —
 * pdfium now does that on every platform from one codebase. The old file is
 * kept verbatim under legacy/android/MainActivity.kt.reference.
 */
class MainActivity : AudioServiceFragmentActivity() {
    private var pendingStorageResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            STORAGE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isGranted" -> result.success(hasDirectStorageAccess())
                "request" -> requestDirectStorageAccess(result)
                "storageRoot" -> result.success(
                    Environment.getExternalStorageDirectory().absolutePath,
                )
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DEVICE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "name" -> result.success(deviceName())
                else -> result.notImplemented()
            }
        }
    }

    /**
     * The name the phone already has.
     *
     * A person with two Samsungs has named them; „Android-Gerät" twice in a
     * list of paired devices helps nobody. DEVICE_NAME is what they set, and
     * the model is a duller but still distinguishing fallback.
     */
    private fun deviceName(): String {
        val chosen = Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME)
        if (!chosen.isNullOrBlank()) return chosen
        val model = Build.MODEL
        if (model.isNullOrBlank()) return "Android-Gerät"
        val brand = Build.MANUFACTURER
        return if (!brand.isNullOrBlank() && !model.startsWith(brand, ignoreCase = true)) {
            "$brand $model"
        } else {
            model
        }
    }

    private fun hasDirectStorageAccess(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            return Environment.isExternalStorageManager()
        }
        val readGranted =
            checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        val writeGranted =
            Build.VERSION.SDK_INT > Build.VERSION_CODES.Q ||
                checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        return readGranted && writeGranted
    }

    private fun requestDirectStorageAccess(result: MethodChannel.Result) {
        if (hasDirectStorageAccess()) {
            result.success(true)
            return
        }
        if (pendingStorageResult != null) {
            result.error(
                "request_in_progress",
                "Eine Speicherfreigabe wird bereits angefordert.",
                null,
            )
            return
        }
        pendingStorageResult = result
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val appSettings = Intent(
                Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                Uri.parse("package:$packageName"),
            )
            try {
                startActivityForResult(appSettings, REQUEST_MANAGE_STORAGE)
            } catch (_: Exception) {
                // Some builds do not carry the per-app screen; the general
                // one is still better than refusing to ask.
                startActivityForResult(
                    Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION),
                    REQUEST_MANAGE_STORAGE,
                )
            }
            return
        }
        requestPermissions(
            arrayOf(
                Manifest.permission.READ_EXTERNAL_STORAGE,
                Manifest.permission.WRITE_EXTERNAL_STORAGE,
            ),
            REQUEST_LEGACY_STORAGE,
        )
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_MANAGE_STORAGE) finishStorageRequest()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_LEGACY_STORAGE) finishStorageRequest()
    }

    private fun finishStorageRequest() {
        val result = pendingStorageResult ?: return
        pendingStorageResult = null
        result.success(hasDirectStorageAccess())
    }

    companion object {
        private const val STORAGE_CHANNEL = "dev.fundus/android_storage_access"
        private const val DEVICE_CHANNEL = "dev.fundus/device"
        private const val REQUEST_MANAGE_STORAGE = 7301
        private const val REQUEST_LEGACY_STORAGE = 7302
    }
}
