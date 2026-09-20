package com.getcapacitor.community.barcodescanner

import android.Manifest
import android.content.Context.MODE_PRIVATE
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.hardware.Camera
import android.net.Uri
import android.provider.Settings
import android.util.Log
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.activity.result.ActivityResult
import com.getcapacitor.JSObject
import com.getcapacitor.PermissionState
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.ActivityCallback
import com.getcapacitor.annotation.CapacitorPlugin
import com.getcapacitor.annotation.Permission
import com.getcapacitor.annotation.PermissionCallback
import com.google.zxing.BarcodeFormat
import com.google.zxing.ResultPoint
import com.google.zxing.client.android.Intents
import com.journeyapps.barcodescanner.BarcodeCallback
import com.journeyapps.barcodescanner.BarcodeResult
import com.journeyapps.barcodescanner.BarcodeView
import com.journeyapps.barcodescanner.DefaultDecoderFactory
import com.journeyapps.barcodescanner.camera.CameraSettings
import org.json.JSONException

@CapacitorPlugin(
    permissions = [Permission(strings = [Manifest.permission.CAMERA], alias = BarcodeScanner.PERMISSION_ALIAS_CAMERA)]
)
public class BarcodeScanner :
    Plugin(),
    BarcodeCallback {
    private var mBarcodeView: BarcodeView? = null

    private var isScanning = false
    private var shouldRunScan = false
    private var didRunCameraSetup = false
    private var didRunCameraPrepare = false
    private var isBackgroundHidden = false
    private var isTorchOn = false
    private var scanningPaused = false
    private var lastScanResult: String? = null

    // The scan call that is waiting for a result. The runtime no longer keeps one for the plugin.
    private var savedCall: PluginCall? = null

    private var savedReturnObject: JSObject? = null

    private fun hasCamera(): Boolean {
        // @TODO(): check: https://stackoverflow.com/a/57974578/8634342
        return activity.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)
    }

    private fun setupCamera(cameraDirection: String?) {
        // @TODO(): add support for switching cameras while scanning is running

        activity.runOnUiThread {
            // Create BarcodeView
            val barcodeView = BarcodeView(activity)
            mBarcodeView = barcodeView

            // Configure the camera (front/back)
            val settings = CameraSettings()
            @Suppress("DEPRECATION")
            settings.requestedCameraId =
                if ("front" == cameraDirection) Camera.CameraInfo.CAMERA_FACING_FRONT else Camera.CameraInfo.CAMERA_FACING_BACK
            settings.isContinuousFocusEnabled = true
            barcodeView.cameraSettings = settings

            val cameraPreviewParams =
                FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT)

            // Set BarcodeView as sibling View of WebView
            (bridge.webView.parent as ViewGroup).addView(barcodeView, cameraPreviewParams)

            // Bring the WebView in front of the BarcodeView
            // This allows us to completely style the BarcodeView in HTML/CSS
            bridge.webView.bringToFront()

            barcodeView.resume()
        }

        didRunCameraSetup = true
    }

    private fun dismantleCamera() {
        // opposite of setupCamera

        activity.runOnUiThread {
            mBarcodeView?.let { barcodeView ->
                barcodeView.pause()
                barcodeView.stopDecoding()
                (bridge.webView.parent as ViewGroup).removeView(barcodeView)
                mBarcodeView = null
            }
        }

        isScanning = false
        didRunCameraSetup = false
        didRunCameraPrepare = false

        // If a call is saved and a scan will not run, free the saved call
        if (savedCall != null && !shouldRunScan) {
            savedCall?.release(bridge)
            savedCall = null
        }
    }

    private fun prepareCamera(call: PluginCall?) {
        // undo previous setup
        // because it may be prepared with a different config
        dismantleCamera()

        // setup camera with new config
        // A scan always has a saved call here; the Java code dereferenced it without a check as well.
        setupCamera(call!!.getString("cameraDirection", "back"))

        // indicate this method was run
        didRunCameraPrepare = true

        if (shouldRunScan) {
            scan()
        }
    }

    private fun destroy() {
        showBackground()
        dismantleCamera()
        setTorch(false)
    }

    private fun configureCamera() {
        activity.runOnUiThread(
            Runnable {
                val call = savedCall
                val barcodeView = mBarcodeView

                if (call == null || barcodeView == null) {
                    Log.d("scanner", "Something went wrong with configuring the BarcodeScanner.")
                    return@Runnable
                }

                var defaultDecoderFactory = DefaultDecoderFactory(null, null, null, Intents.Scan.MIXED_SCAN)

                if (call.data.has("targetedFormats")) {
                    val targetedFormats = call.getArray("targetedFormats")
                    val formatList = ArrayList<BarcodeFormat>()

                    if (targetedFormats != null && targetedFormats.length() > 0) {
                        for (i in 0 until targetedFormats.length()) {
                            try {
                                val targetedFormat = targetedFormats.getString(i)
                                SUPPORTED_FORMATS[targetedFormat]?.let { formatList.add(it) }
                            } catch (e: JSONException) {
                                e.printStackTrace()
                            }
                        }
                    }

                    if (formatList.isNotEmpty()) {
                        defaultDecoderFactory = DefaultDecoderFactory(formatList, null, null, Intents.Scan.MIXED_SCAN)
                    } else {
                        Log.d("scanner", "The property targetedFormats was not set correctly.")
                    }
                }

                barcodeView.decoderFactory = defaultDecoderFactory
            }
        )
    }

    private fun scan() {
        if (!didRunCameraPrepare) {
            if (hasCamera()) {
                if (context.checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
                    Log.d("scanner", "No permission to use camera. Did you request it yet?")
                } else {
                    shouldRunScan = true
                    prepareCamera(savedCall)
                }
            }
        } else {
            didRunCameraPrepare = false

            shouldRunScan = false

            configureCamera()

            activity.runOnUiThread {
                mBarcodeView?.let { barcodeView ->
                    if (savedCall?.keepAlive == true) {
                        barcodeView.decodeContinuous(this)
                    } else {
                        barcodeView.decodeSingle(this)
                    }
                }
            }

            hideBackground()

            isScanning = true
        }
    }

    private fun hideBackground() {
        activity.runOnUiThread {
            bridge.webView.setBackgroundColor(Color.TRANSPARENT)
            bridge.webView.loadUrl("javascript:document.documentElement.style.backgroundColor = 'transparent';void(0);")
            isBackgroundHidden = true
        }
    }

    private fun showBackground() {
        activity.runOnUiThread {
            bridge.webView.setBackgroundColor(Color.WHITE)
            bridge.webView.loadUrl("javascript:document.documentElement.style.backgroundColor = '';void(0);")
            isBackgroundHidden = false
        }
    }

    override fun barcodeResult(barcodeResult: BarcodeResult) {
        val jsObject = JSObject()
        val text: String? = barcodeResult.text

        if (text != null) {
            jsObject.put("hasContent", true)
            jsObject.put("content", text)
            jsObject.put("format", barcodeResult.barcodeFormat.name)
        } else {
            jsObject.put("hasContent", false)
        }

        val call = savedCall

        if (call != null) {
            if (call.keepAlive) {
                if (!scanningPaused && text != null && text != lastScanResult) {
                    lastScanResult = text
                    call.resolve(jsObject)
                }
            } else {
                call.resolve(jsObject)
                destroy()
            }
        } else {
            destroy()
        }
    }

    protected override fun handleOnPause() {
        mBarcodeView?.pause()
    }

    protected override fun handleOnResume() {
        mBarcodeView?.resume()
    }

    override fun possibleResultPoints(resultPoints: List<ResultPoint>) {}

    @PluginMethod
    public fun prepare(call: PluginCall) {
        prepareCamera(call)
        call.resolve()
    }

    @PluginMethod
    public fun hideBackground(call: PluginCall) {
        hideBackground()
        call.resolve()
    }

    @PluginMethod
    public fun showBackground(call: PluginCall) {
        showBackground()
        call.resolve()
    }

    @PluginMethod
    public fun startScan(call: PluginCall) {
        savedCall = call
        scan()
    }

    @PluginMethod
    public fun stopScan(call: PluginCall) {
        if (call.data.has("resolveScan") && savedCall != null) {
            if (call.getBoolean("resolveScan", false) == true) {
                val jsObject = JSObject()
                jsObject.put("hasContent", false)

                savedCall?.resolve(jsObject)
            }
        }

        destroy()
        call.resolve()
    }

    @PluginMethod(returnType = PluginMethod.RETURN_CALLBACK)
    public fun startScanning(call: PluginCall) {
        call.keepAlive = true
        lastScanResult = null // reset when scanning again
        savedCall = call
        scanningPaused = false
        scan()
    }

    @PluginMethod
    public fun pauseScanning(call: PluginCall) {
        scanningPaused = true
        call.resolve()
    }

    @PluginMethod
    public fun resumeScanning(call: PluginCall) {
        lastScanResult = null // reset when scanning again
        scanningPaused = false
        call.resolve()
    }

    private fun checkPermission(call: PluginCall, force: Boolean) {
        val returnObject = JSObject()
        savedReturnObject = returnObject

        if (getPermissionState(PERMISSION_ALIAS_CAMERA) == PermissionState.GRANTED) {
            // permission GRANTED
            returnObject.put(GRANTED, true)
        } else {
            // permission NOT YET GRANTED

            // check if asked before
            val neverAsked = isPermissionFirstTimeAsking(PERMISSION_NAME)
            if (neverAsked) {
                returnObject.put(NEVER_ASKED, true)
            }

            // on runtime,
            // each permission can be temporarily denied,
            // or be denied forever
            if (neverAsked || activity.shouldShowRequestPermissionRationale(PERMISSION_NAME)) {
                // permission never asked before
                // OR
                // permission DENIED, BUT not for always
                // So
                // can be asked (again)
                if (force) {
                    // request permission
                    // so a callback can be made from the handleRequestPermissionsResult
                    requestPermissionForAlias(PERMISSION_ALIAS_CAMERA, call, "cameraPermsCallback")
                    return
                }
            } else {
                // permission DENIED
                // user ALSO checked "NEVER ASK AGAIN"
                returnObject.put(DENIED, true)
            }
        }
        call.resolve(returnObject)
    }

    private fun setPermissionFirstTimeAsking(permission: String, isFirstTime: Boolean) {
        val sharedPreference = activity.getSharedPreferences(PREFS_PERMISSION_FIRST_TIME_ASKING, MODE_PRIVATE)
        sharedPreference.edit().putBoolean(permission, isFirstTime).apply()
    }

    private fun isPermissionFirstTimeAsking(permission: String): Boolean =
        activity.getSharedPreferences(PREFS_PERMISSION_FIRST_TIME_ASKING, MODE_PRIVATE).getBoolean(permission, true)

    @PermissionCallback
    private fun cameraPermsCallback(call: PluginCall) {
        // No stored plugin call for permissions request result
        val returnObject = savedReturnObject ?: return

        // the user was apparently requested this permission
        // update the preferences to reflect this
        setPermissionFirstTimeAsking(PERMISSION_NAME, false)

        val granted = getPermissionState(PERMISSION_ALIAS_CAMERA) == PermissionState.GRANTED

        // indicate that the user has been asked to accept this permission
        returnObject.put(ASKED, true)

        if (granted) {
            // permission GRANTED
            Log.d(TAG_PERMISSION, "Asked. Granted")
            returnObject.put(GRANTED, true)
        } else if (activity.shouldShowRequestPermissionRationale(PERMISSION_NAME)) {
            // permission DENIED
            // BUT not for always
            Log.d(TAG_PERMISSION, "Asked. Denied For Now")
        } else {
            // permission DENIED
            // user ALSO checked "NEVER ASK AGAIN"
            Log.d(TAG_PERMISSION, "Asked. Denied")
            returnObject.put(DENIED, true)
        }
        // resolve saved call
        call.resolve(returnObject)
        // release saved vars
        savedReturnObject = null
    }

    @PluginMethod
    public fun checkPermission(call: PluginCall) {
        checkPermission(call, call.getBoolean("force", false) == true)
    }

    @PluginMethod
    public fun openAppSettings(call: PluginCall) {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", appId, null))
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivityForResult(call, intent, "openSettingsResult")
    }

    @Suppress("UNUSED_PARAMETER")
    @ActivityCallback
    private fun openSettingsResult(call: PluginCall, result: ActivityResult) {
        call.resolve()
    }

    private fun setTorch(on: Boolean) {
        if (on != isTorchOn) {
            isTorchOn = on
            activity.runOnUiThread { mBarcodeView?.setTorch(on) }
        }
    }

    @PluginMethod
    public fun enableTorch(call: PluginCall) {
        setTorch(true)
        call.resolve()
    }

    @PluginMethod
    public fun disableTorch(call: PluginCall) {
        setTorch(false)
        call.resolve()
    }

    @PluginMethod
    public fun toggleTorch(call: PluginCall) {
        setTorch(!isTorchOn)
        call.resolve()
    }

    @PluginMethod
    public fun getTorchState(call: PluginCall) {
        val result = JSObject()

        result.put("isEnabled", isTorchOn)

        call.resolve(result)
    }

    public companion object {
        public const val PERMISSION_ALIAS_CAMERA: String = "camera"

        private const val TAG_PERMISSION = "permission"

        private const val GRANTED = "granted"
        private const val DENIED = "denied"
        private const val ASKED = "asked"
        private const val NEVER_ASKED = "neverAsked"

        private const val PERMISSION_NAME = Manifest.permission.CAMERA

        private const val PREFS_PERMISSION_FIRST_TIME_ASKING = "PREFS_PERMISSION_FIRST_TIME_ASKING"

        // allowed barcode formats
        private val SUPPORTED_FORMATS: Map<String, BarcodeFormat> =
            mapOf(
                // 1D Product
                "UPC_A" to BarcodeFormat.UPC_A,
                "UPC_E" to BarcodeFormat.UPC_E,
                "UPC_EAN_EXTENSION" to BarcodeFormat.UPC_EAN_EXTENSION,
                "EAN_8" to BarcodeFormat.EAN_8,
                "EAN_13" to BarcodeFormat.EAN_13,
                // 1D Industrial
                "CODE_39" to BarcodeFormat.CODE_39,
                "CODE_93" to BarcodeFormat.CODE_93,
                "CODE_128" to BarcodeFormat.CODE_128,
                "CODABAR" to BarcodeFormat.CODABAR,
                "ITF" to BarcodeFormat.ITF,
                // 2D
                "AZTEC" to BarcodeFormat.AZTEC,
                "DATA_MATRIX" to BarcodeFormat.DATA_MATRIX,
                "MAXICODE" to BarcodeFormat.MAXICODE,
                "PDF_417" to BarcodeFormat.PDF_417,
                "QR_CODE" to BarcodeFormat.QR_CODE,
                "RSS_14" to BarcodeFormat.RSS_14,
                "RSS_EXPANDED" to BarcodeFormat.RSS_EXPANDED
            )
    }
}
