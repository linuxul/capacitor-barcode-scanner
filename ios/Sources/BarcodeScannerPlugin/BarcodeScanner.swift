import Capacitor
import Foundation
import UIKit
import AVFoundation

@objc(BarcodeScanner)
public class BarcodeScanner: CAPPlugin, CAPBridgedPlugin, AVCaptureMetadataOutputObjectsDelegate {
    public let identifier = "BarcodeScanner"
    public let jsName = "BarcodeScanner"
    public let pluginMethods: [CAPPluginMethod] = [
        .promise("prepare", BarcodeScanner.prepare),
        .promise("hideBackground", BarcodeScanner.hideBackground),
        .promise("showBackground", BarcodeScanner.showBackground),
        .promise("startScan", BarcodeScanner.startScan),
        .callback("startScanning", BarcodeScanner.startScanning),
        .promise("stopScan", BarcodeScanner.stopScan),
        .promise("pauseScanning", BarcodeScanner.pauseScanning),
        .promise("resumeScanning", BarcodeScanner.resumeScanning),
        .async("checkPermission", BarcodeScanner.checkPermission),
        .async("openAppSettings", BarcodeScanner.openAppSettings),
        .promise("enableTorch", BarcodeScanner.enableTorch),
        .promise("disableTorch", BarcodeScanner.disableTorch),
        .promise("toggleTorch", BarcodeScanner.toggleTorch),
        .promise("getTorchState", BarcodeScanner.getTorchState)
    ]

    class CameraView: UIView {
        var videoPreviewLayer:AVCaptureVideoPreviewLayer?

        func interfaceOrientationToVideoOrientation(_ orientation : UIInterfaceOrientation) -> AVCaptureVideoOrientation {
            switch (orientation) {
            case UIInterfaceOrientation.portrait:
                return AVCaptureVideoOrientation.portrait
            case UIInterfaceOrientation.portraitUpsideDown:
                return AVCaptureVideoOrientation.portraitUpsideDown
            case UIInterfaceOrientation.landscapeLeft:
                return AVCaptureVideoOrientation.landscapeLeft
            case UIInterfaceOrientation.landscapeRight:
                return AVCaptureVideoOrientation.landscapeRight
            default:
                return AVCaptureVideoOrientation.portraitUpsideDown
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let sublayers = self.layer.sublayers {
                for layer in sublayers {
                    layer.frame = self.bounds
                }
            }
            
            if let interfaceOrientation = UIApplication.shared.windows.first(where: { $0.isKeyWindow })?.windowScene?.interfaceOrientation {
                self.videoPreviewLayer?.connection?.videoOrientation = interfaceOrientationToVideoOrientation(interfaceOrientation)
            }
        }


        func addPreviewLayer(_ previewLayer:AVCaptureVideoPreviewLayer?) {
            previewLayer!.videoGravity = AVLayerVideoGravity.resizeAspectFill
            previewLayer!.frame = self.bounds
            self.layer.addSublayer(previewLayer!)
            self.videoPreviewLayer = previewLayer
        }

        func removePreviewLayer() {
            if self.videoPreviewLayer != nil {
                self.videoPreviewLayer!.removeFromSuperlayer()
                self.videoPreviewLayer = nil
            }
        }
    }

    var cameraView: CameraView!
    var captureSession:AVCaptureSession?
    var captureVideoPreviewLayer:AVCaptureVideoPreviewLayer?
    var metaOutput: AVCaptureMetadataOutput?

    var currentCamera: Int = 0
    var frontCamera: AVCaptureDevice?
    var backCamera: AVCaptureDevice?

    var isScanning: Bool = false
    var shouldRunScan: Bool = false
    var didRunCameraSetup: Bool = false
    var didRunCameraPrepare: Bool = false
    var isBackgroundHidden: Bool = false
    var previousBackgroundColor: UIColor? = UIColor.white

    var savedCall: CAPPluginCall? = nil
    var scanningPaused: Bool = false
    var lastScanResult: String? = nil

    enum SupportedFormat: String, CaseIterable {
        // 1D Product
        //!\ UPC_A is part of EAN_13 according to Apple docs
        case UPC_E
        //!\ UPC_EAN_EXTENSION is not supported by AVFoundation
        case EAN_8
        case EAN_13
        // 1D Industrial
        case CODE_39
        case CODE_39_MOD_43
        case CODE_93
        case CODE_128
        //!\ CODABAR is not supported by AVFoundation
        case ITF
        case ITF_14
        // 2D
        case AZTEC
        case DATA_MATRIX
        //!\ MAXICODE is not supported by AVFoundation
        case PDF_417
        case QR_CODE
        //!\ RSS_14 is not supported by AVFoundation
        //!\ RSS_EXPANDED is not supported by AVFoundation

        var value: AVMetadataObject.ObjectType {
            switch self {
                // 1D Product
                case .UPC_E: return AVMetadataObject.ObjectType.upce
                case .EAN_8: return AVMetadataObject.ObjectType.ean8
                case .EAN_13: return AVMetadataObject.ObjectType.ean13
                // 1D Industrial
                case .CODE_39: return AVMetadataObject.ObjectType.code39
                case .CODE_39_MOD_43: return AVMetadataObject.ObjectType.code39Mod43
                case .CODE_93: return AVMetadataObject.ObjectType.code93
                case .CODE_128: return AVMetadataObject.ObjectType.code128
                case .ITF: return AVMetadataObject.ObjectType.interleaved2of5
                case .ITF_14: return AVMetadataObject.ObjectType.itf14
                // 2D
                case .AZTEC: return AVMetadataObject.ObjectType.aztec
                case .DATA_MATRIX: return AVMetadataObject.ObjectType.dataMatrix
                case .PDF_417: return AVMetadataObject.ObjectType.pdf417
                case .QR_CODE: return AVMetadataObject.ObjectType.qr
            }
        }
    }

    var targetedFormats = [AVMetadataObject.ObjectType]()

    enum CaptureError: Error {
        case backCameraUnavailable
        case frontCameraUnavailable
        case couldNotCaptureInput(error: NSError)
    }

    public override func load() {
        self.cameraView = CameraView(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height))
        self.cameraView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    private func setupCamera(cameraDirection: String? = "back") -> Bool {
        do {
            var cameraDir = cameraDirection
            cameraView.backgroundColor = UIColor.clear
            self.webView!.superview!.insertSubview(cameraView, belowSubview: self.webView!)
            
            let availableVideoDevices =  discoverCaptureDevices()
            for device in availableVideoDevices {
                if device.position == AVCaptureDevice.Position.back {
                    backCamera = device
                }
                else if device.position == AVCaptureDevice.Position.front {
                    frontCamera = device
                }
            }
            // older iPods have no back camera
            if (cameraDir == "back") {
                if (backCamera == nil) {
                    cameraDir = "front"
                }
            } else {
                if (frontCamera == nil) {
                    cameraDir = "back"
                }
            }
            let input: AVCaptureDeviceInput
            input = try self.createCaptureDeviceInput(cameraDirection: cameraDir)
            captureSession = AVCaptureSession()
            captureSession!.addInput(input)
            metaOutput = AVCaptureMetadataOutput()
            captureSession!.addOutput(metaOutput!)
            metaOutput!.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            captureVideoPreviewLayer = AVCaptureVideoPreviewLayer(session: captureSession!)
            cameraView.addPreviewLayer(captureVideoPreviewLayer)
            self.didRunCameraSetup = true
            return true
        } catch CaptureError.backCameraUnavailable {
            //
        } catch CaptureError.frontCameraUnavailable {
            //
        } catch CaptureError.couldNotCaptureInput {
            //
        } catch {
            //
        }
        return false
    }

    @available(swift, deprecated: 5.6, message: "New Xcode? Check if `AVCaptureDevice.DeviceType` has new types and add them accordingly.")
    private func discoverCaptureDevices() -> [AVCaptureDevice] {
        return AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInTripleCamera, .builtInDualCamera, .builtInTelephotoCamera, .builtInTrueDepthCamera, .builtInUltraWideCamera, .builtInDualWideCamera, .builtInWideAngleCamera], mediaType: .video, position: .unspecified).devices
    }

    private func createCaptureDeviceInput(cameraDirection: String? = "back") throws -> AVCaptureDeviceInput {
        var captureDevice: AVCaptureDevice
        if(cameraDirection == "back"){
            if(backCamera != nil){
                captureDevice = backCamera!
            } else {
                throw CaptureError.backCameraUnavailable
            }
        } else {
            if(frontCamera != nil){
                captureDevice = frontCamera!
            } else {
                throw CaptureError.frontCameraUnavailable
            }
        }
        let captureDeviceInput: AVCaptureDeviceInput
        do {
            captureDeviceInput = try AVCaptureDeviceInput(device: captureDevice)
        } catch let error as NSError {
            throw CaptureError.couldNotCaptureInput(error: error)
        }
        return captureDeviceInput
    }

    private func dismantleCamera() {
        // opposite of setupCamera

        
        DispatchQueue.main.async {
            if (self.captureSession != nil) {
                self.captureSession!.stopRunning()
                self.cameraView.removePreviewLayer()
                self.captureVideoPreviewLayer = nil
                self.metaOutput = nil
                self.captureSession = nil
                self.frontCamera = nil
                self.backCamera = nil
            }
        }

        self.isScanning = false
        self.didRunCameraSetup = false
        self.didRunCameraPrepare = false

        // If a call is saved and a scan will not run, free the saved call
        if (self.savedCall != nil && !self.shouldRunScan) {
            self.releaseSavedCall()
        }
    }

    private func prepareCamera(_ call: CAPPluginCall? = nil) {
        // undo previous setup
        // because it may be prepared with a different config
        self.dismantleCamera()

        DispatchQueue.main.async {
            // setup camera with new config
            if (self.setupCamera(cameraDirection: call?.getString("cameraDirection") ?? "back")) {
                // indicate this method was run
                self.didRunCameraPrepare = true

                if (self.shouldRunScan) {
                    self.scan()
                }
            } else {
                self.shouldRunScan = false
            }
        }
    }

    /// Forgets the scan call. A startScanning call is kept alive: the bridge keeps it until it is released.
    private func releaseSavedCall() {
        if let call = self.savedCall, call.keepAlive {
            self.bridge?.releaseCall(call)
        }
        self.savedCall = nil
    }

    private func destroy() {
        self.showBackground()

        self.dismantleCamera()
    }

    private func scan() {
        if (!self.didRunCameraPrepare) {
            // From iOS 14 on the needed permission is not identified up front, so the scan is prepared
            // without checking it and the system asks when the camera is opened.
            DispatchQueue.main.async {
                self.load()
                self.shouldRunScan = true
                self.prepareCamera(self.savedCall)
            }
        } else {
            self.didRunCameraPrepare = false

            self.shouldRunScan = false

            targetedFormats = [AVMetadataObject.ObjectType]();

            if ((savedCall?.options["targetedFormats"]) != nil) {
                let _targetedFormats = savedCall?.getArray("targetedFormats", String.self)

                if (_targetedFormats != nil && _targetedFormats?.count ?? 0 > 0) {
                    _targetedFormats?.forEach { targetedFormat in
                        if let value = SupportedFormat(rawValue: targetedFormat)?.value {
                            print(value)
                            targetedFormats.append(value)
                        }
                    }
                }

                if (targetedFormats.count == 0) {
                    print("The property targetedFormats was not set correctly.")
                }
            }

            if (targetedFormats.count == 0) {
                for supportedFormat in SupportedFormat.allCases {
                    targetedFormats.append(supportedFormat.value)
                }
            }

            DispatchQueue.main.async {
                self.metaOutput!.metadataObjectTypes = self.targetedFormats
                self.captureSession!.startRunning()
            }

            self.hideBackground()

            self.isScanning = true
        }
    }

    private func hideBackground() {
        DispatchQueue.main.async {
            self.previousBackgroundColor = self.bridge?.webView!.backgroundColor

            self.bridge?.webView!.isOpaque = false
            self.bridge?.webView!.backgroundColor = UIColor.clear
            self.bridge?.webView!.scrollView.backgroundColor = UIColor.clear

            let javascript = "document.documentElement.style.backgroundColor = 'transparent'"

            self.bridge?.webView!.evaluateJavaScript(javascript)
        }
    }

    private func showBackground() {
        DispatchQueue.main.async {
            let javascript = "document.documentElement.style.backgroundColor = ''"

            self.bridge?.webView!.evaluateJavaScript(javascript) { (result, error) in
                self.bridge?.webView!.isOpaque = true
                self.bridge?.webView!.backgroundColor = self.previousBackgroundColor
                self.bridge?.webView!.scrollView.backgroundColor = self.previousBackgroundColor
            }
        }
    }

    // This method processes metadataObjects captured by iOS.
    public func metadataOutput(_ captureOutput: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {

        if (metadataObjects.count == 0 || !self.isScanning) {
            // while nothing is detected, or if scanning is false, do nothing.
            return
        }

        let found = metadataObjects[0] as! AVMetadataMachineReadableCodeObject
        if (targetedFormats.contains(found.type)) {
            var jsObject = PluginCallResultData()

            if (found.stringValue != nil) {
                jsObject["hasContent"] = true
                jsObject["content"] = found.stringValue
                jsObject["format"] = formatStringFromMetadata(found.type)
            } else {
                jsObject["hasContent"] = false
            }

            if (savedCall != nil) {
                if (savedCall!.keepAlive) {
                    if (!scanningPaused && found.stringValue != lastScanResult ) {
                        lastScanResult = found.stringValue
                        savedCall!.resolve(jsObject)
                    }
                } else {
                    savedCall!.resolve(jsObject)
                    savedCall = nil
                    destroy()
                }
            } else {
                self.destroy()
            }
        }
    }

    private func formatStringFromMetadata(_ type: AVMetadataObject.ObjectType) -> String {
            switch type {
            case AVMetadataObject.ObjectType.upce:
                return "UPC_E"
            case AVMetadataObject.ObjectType.ean8:
                return "EAN_8"
            case AVMetadataObject.ObjectType.ean13:
                return "EAN_13"
            case AVMetadataObject.ObjectType.code39:
                return "CODE_39"
            case AVMetadataObject.ObjectType.code39Mod43:
                return "CODE_39_MOD_43"
            case AVMetadataObject.ObjectType.code93:
                return "CODE_93"
            case AVMetadataObject.ObjectType.code128:
                return "CODE_128"
            case AVMetadataObject.ObjectType.interleaved2of5:
                return "ITF"
            case AVMetadataObject.ObjectType.itf14:
                return "ITF_14"
            case AVMetadataObject.ObjectType.aztec:
                return "AZTEC"
            case AVMetadataObject.ObjectType.dataMatrix:
                return "DATA_MATRIX"
            case AVMetadataObject.ObjectType.pdf417:
                return "PDF_417"
            case AVMetadataObject.ObjectType.qr:
                return "QR_CODE"
            default:
                return type.rawValue
            }
        }

    func prepare(_ call: CAPPluginCall) {
        self.prepareCamera()
        call.resolve()
    }

    func hideBackground(_ call: CAPPluginCall) {
        self.hideBackground()
        call.resolve()
    }

    func showBackground(_ call: CAPPluginCall) {
        self.showBackground()
        call.resolve()
    }

    func startScan(_ call: CAPPluginCall) {
        self.savedCall = call
        self.scan()
    }

    func startScanning(_ call: CAPPluginCall) {
        self.savedCall = call
        self.savedCall?.keepAlive = true
        scanningPaused = false
        lastScanResult = nil
        self.scan()
    }

    func pauseScanning(_ call: CAPPluginCall) {
        scanningPaused = true
        call.resolve()
    }

    func resumeScanning(_ call: CAPPluginCall) {
       lastScanResult = nil
        scanningPaused = false
        call.resolve()
    }

    func stopScan(_ call: CAPPluginCall) {
        if ((call.getBool("resolveScan") ?? false) && self.savedCall != nil) {
            var jsObject = PluginCallResultData()
            jsObject["hasContent"] = false

            savedCall?.resolve(jsObject)
            releaseSavedCall()
        }

        self.destroy()
        call.resolve()
    }

    /// Reads the camera authorization and, with `force` and a permission never asked for, asks for it and waits for
    /// the answer. It ran on the main queue: the method runs on the main actor.
    @MainActor
    func checkPermission(_ call: CAPPluginCall) async -> JSObject {
        let force = call.getBool("force") ?? false

        var savedReturnObject = JSObject()

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            savedReturnObject["granted"] = true
        case .denied:
            savedReturnObject["denied"] = true
        case .notDetermined:
            savedReturnObject["neverAsked"] = true
        case .restricted:
            savedReturnObject["restricted"] = true
        @unknown default:
            savedReturnObject["unknown"] = true
        }

        if force && savedReturnObject["neverAsked"] != nil {
            savedReturnObject["asked"] = true

            if await AVCaptureDevice.requestAccess(for: .video) {
                savedReturnObject["granted"] = true
            } else {
                savedReturnObject["denied"] = true
            }
        }
        return savedReturnObject
    }

    /// Opens the app's page in Settings and returns when the system has handled the request.
    @MainActor
    func openAppSettings(_ call: CAPPluginCall) async {
        guard let settingsUrl = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(settingsUrl) else {
            return
        }
        _ = await UIApplication.shared.open(settingsUrl)
    }

    // Without a camera or a usable torch there is nothing to switch: the torch methods resolve, as on Android. They
    // used to leave the call pending.

    func enableTorch(_ call: CAPPluginCall) {
        guard let device = AVCaptureDevice.default(for: AVMediaType.video),
              device.hasTorch, device.isTorchAvailable else {
            call.resolve()
            return
        }

        do {
            try device.lockForConfiguration()

            do {
                try device.setTorchModeOn(level: 1.0)
            } catch {
                print(error)
            }

            device.unlockForConfiguration()
        } catch {
            print(error)
        }

        call.resolve()
    }

    func disableTorch(_ call: CAPPluginCall) {
        guard let device = AVCaptureDevice.default(for: AVMediaType.video),
              device.hasTorch, device.isTorchAvailable else {
            call.resolve()
            return
        }

        do {
            try device.lockForConfiguration()
            device.torchMode = .off

            device.unlockForConfiguration()
        } catch {
            print(error)
        }

        call.resolve()
    }

    func toggleTorch(_ call: CAPPluginCall) {
        guard let device = AVCaptureDevice.default(for: AVMediaType.video),
              device.hasTorch, device.isTorchAvailable else {
            call.resolve()
            return
        }

        if (device.torchMode == .on) {
            self.disableTorch(call)
        } else {
            self.enableTorch(call)
        }
    }

    func getTorchState(_ call: CAPPluginCall) {
        guard let device = AVCaptureDevice.default(for: AVMediaType.video) else {
            call.resolve(["isEnabled": false])
            return
        }

        var result = PluginCallResultData()

        result["isEnabled"] = device.torchMode == .on

        call.resolve(result)
    }

}
