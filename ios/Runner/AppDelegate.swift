import AVFoundation
import CoreImage
import Flutter
import Network
import NetworkExtension
import PhotosUI
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, FlutterStreamHandler {
    static let appGroupId = "group.app.tachyon.proxy"
    static weak var shared: AppDelegate?

    private var methodChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?

    private var vpnManager: NETunnelProviderManager?
    private var currentServerName: String = ""
    private var lastTunnelError: String = ""
    private var pendingLaunchLink: String?

    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "app.tachyon.proxy.netmonitor")
    private var currentNetworkType: String = "wifi"

    private var workingDirectory: URL {
        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupId) {
            try? FileManager.default.createDirectory(at: groupURL, withIntermediateDirectories: true)
            return groupURL
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("tachyon", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport
    }

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        Self.shared = self
        startNetworkMonitor()

        if let url = launchOptions?[.url] as? URL {
            handleIncomingURL(url)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(vpnStatusDidChange(_:)),
            name: .NEVPNStatusDidChange,
            object: nil
        )

        loadExistingVpnManager { _ in }
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
        GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
        guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "TachyonVpnBridge") else {
            return
        }
        setupChannels(messenger: registrar.messenger())
    }

    func setupChannelsIfNeeded(binaryMessenger: FlutterBinaryMessenger) {
        if methodChannel == nil {
            setupChannels(messenger: binaryMessenger)
        }
    }

    private func setupChannels(messenger: FlutterBinaryMessenger) {
        let method = FlutterMethodChannel(name: "app.tachyon.proxy/vpn", binaryMessenger: messenger)
        method.setMethodCallHandler { [weak self] call, result in
            self?.handleMethodCall(call, result: result)
        }
        self.methodChannel = method

        let events = FlutterEventChannel(name: "app.tachyon.proxy/events", binaryMessenger: messenger)
        events.setStreamHandler(self)
        self.eventChannel = events
    }

    override func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        handleIncomingURL(url)
        return true
    }

    func handleIncomingURL(_ url: URL) {
        let raw = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        if let sink = eventSink {
            sink(["type": "deeplink", "url": raw])
        } else {
            pendingLaunchLink = raw
        }
    }

    // MARK: - FlutterStreamHandler

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        emitCurrentVpnState()
        if let link = pendingLaunchLink, !link.isEmpty {
            pendingLaunchLink = nil
            events(["type": "deeplink", "url": link])
        }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }

    // MARK: - MethodChannel Dispatch

    private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]

        switch call.method {
        case "version":
            if let ptr = tachyon_core_version() {
                result(String(cString: ptr))
            } else {
                result("0.3.1")
            }

        case "check":
            let config = (args?["config"] as? String) ?? ""
            DispatchQueue.global(qos: .userInitiated).async {
                let rc = config.withCString { cstr in
                    tachyon_core_check(cstr)
                }
                if rc == 0 {
                    DispatchQueue.main.async {
                        result("{\"ok\":true,\"warnings\":[]}")
                    }
                } else {
                    let err = Self.consumeCoreLastError() ?? "ошибка проверки конфигурации"
                    let payload: [String: Any] = ["ok": false, "error": err]
                    let json = Self.encodeJsonString(payload) ?? "{\"ok\":false,\"error\":\"invalid config\"}"
                    DispatchQueue.main.async {
                        result(json)
                    }
                }
            }

        case "fetchSubscription":
            // В iOS используем Dart-каскад загрузки подписок
            result(nil)

        case "parseSubscription":
            // В iOS используем встроенный универсальный парсер подписок
            result(nil)

        case "start":
            let config = (args?["config"] as? String) ?? ""
            let serverName = (args?["serverName"] as? String) ?? ""
            let mtu = (args?["mtu"] as? Int) ?? 9000
            let proxyOnly = (args?["proxyOnly"] as? Bool) ?? false
            startVpnTunnel(config: config, serverName: serverName, mtu: mtu, proxyOnly: proxyOnly, result: result)

        case "stop":
            stopVpnTunnel(result: result)

        case "status":
            queryCurrentStatus(result: result)

        case "stats":
            queryTrafficStats(result: result)

        case "logs":
            let limit = (args?["limit"] as? Int) ?? 400
            queryLogs(limit: limit, result: result)

        case "clearLogs":
            clearTunnelLogs(result: result)

        case "filesDir":
            result(workingDirectory.path)

        case "deviceAbi":
            result("ios-arm64")

        case "networkInfo":
            result(currentNetworkType)

        case "wifiInfo":
            if #available(iOS 14.0, *) {
                NEHotspotNetwork.fetchCurrent { [weak self] network in
                    let ssid = network?.ssid ?? ""
                    let isWifi = (self?.currentNetworkType == "wifi")
                    result([
                        "ssid": ssid,
                        "isWifi": isWifi,
                        "hasPermission": true,
                        "locationEnabled": true,
                        "nearbySsids": ssid.isEmpty ? [String]() : [ssid],
                        "pausedWifiSsid": "",
                    ])
                }
            } else {
                result([
                    "ssid": "",
                    "isWifi": currentNetworkType == "wifi",
                    "hasPermission": true,
                    "locationEnabled": true,
                    "nearbySsids": [String](),
                    "pausedWifiSsid": "",
                ])
            }

        case "requestWifiPermission", "openLocationSettings", "recheckHomeWifi", "forceResumeFromWifi":
            result(true)

        case "consumeLaunchLink":
            let link = pendingLaunchLink
            pendingLaunchLink = nil
            result(link)

        case "apps":
            result([Any]())

        case "appIcon":
            result(nil)

        case "shareText":
            let text = (args?["text"] as? String) ?? ""
            let subject = (args?["subject"] as? String) ?? ""
            presentShareSheet(items: [text], subject: subject)
            result(true)

        case "openUrl":
            guard let rawUrl = args?["url"] as? String,
                  let url = URL(string: rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                result(false)
                return
            }
            UIApplication.shared.open(url, options: [:]) { ok in
                result(ok)
            }

        case "scanQr":
            let fromGallery = (args?["fromGallery"] as? Bool) ?? false
            if fromGallery {
                presentGalleryQrPicker(result: result)
            } else {
                presentCameraQrScanner(result: result)
            }

        case "installEngineSo":
            result("requires_apk")

        case "installApk":
            let fileName = (args?["fileName"] as? String) ?? "tachyon-proxy-ios.ipa"
            let fileURL = workingDirectory.appendingPathComponent("update").appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                presentShareSheet(items: [fileURL], subject: "Tachyon Proxy IPA")
                result("ok")
            } else {
                result("error: файл \(fileName) не найден")
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - VPN Lifecycle (NETunnelProviderManager)

    private func loadExistingVpnManager(completion: @escaping (NETunnelProviderManager?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            guard let self = self else {
                completion(nil)
                return
            }
            if let first = managers?.first {
                self.vpnManager = first
                completion(first)
            } else {
                completion(nil)
            }
        }
    }

    private func getOrCreateVpnManager(completion: @escaping (NETunnelProviderManager?, Error?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            if let error = error {
                completion(nil, error)
                return
            }
            let manager = managers?.first ?? NETunnelProviderManager()
            self?.vpnManager = manager
            completion(manager, nil)
        }
    }

    private func startVpnTunnel(
        config: String,
        serverName: String,
        mtu: Int,
        proxyOnly: Bool,
        result: @escaping FlutterResult
    ) {
        guard !config.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            result("Пустая конфигурация туннеля")
            return
        }

        // Проверяем конфигурацию ядром до запуска NetworkExtension
        let checkRc = config.withCString { cstr in
            tachyon_core_check(cstr)
        }
        if checkRc != 0 {
            let err = Self.consumeCoreLastError() ?? "Конфигурация отклонена ядром tachyon-core"
            result(err)
            return
        }

        currentServerName = serverName
        lastTunnelError = ""

        // Сохраняем конфиг в общий контейнер
        let activeConfigURL = workingDirectory.appendingPathComponent("active_config.json")
        try? config.write(to: activeConfigURL, atomically: true, encoding: .utf8)

        // Собираем используемые бинарные списки .trs для передачи в providerConfiguration
        let trsFiles = collectReferencedTrsFiles(from: config)

        getOrCreateVpnManager { [weak self] manager, error in
            guard let self = self else { return }
            if let error = error {
                result("Ошибка доступа к VPN-профилю iOS: \(error.localizedDescription)")
                return
            }
            guard let manager = manager else {
                result("Не удалось создать NETunnelProviderManager")
                return
            }

            let baseBundleId = Bundle.main.bundleIdentifier ?? "app.tachyon.tachyonProxy"
            let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
            proto.providerBundleIdentifier = "\(baseBundleId).PacketTunnel"
            proto.serverAddress = serverName.isEmpty ? "Tachyon" : serverName
            var providerConfig: [String: Any] = [
                "config": config,
                "serverName": serverName,
                "mtu": mtu,
                "proxyOnly": proxyOnly,
            ]
            if !trsFiles.isEmpty {
                providerConfig["trsFiles"] = trsFiles
            }
            proto.providerConfiguration = providerConfig

            manager.protocolConfiguration = proto
            manager.localizedDescription = serverName.isEmpty ? "Tachyon Proxy" : "Tachyon · \(serverName)"
            manager.isEnabled = true

            manager.saveToPreferences { saveError in
                if let saveError = saveError {
                    result("Не удалось сохранить VPN-профиль iOS: \(saveError.localizedDescription)")
                    return
                }
                manager.loadFromPreferences { loadError in
                    if let loadError = loadError {
                        result("Не удалось перезагрузить VPN-профиль iOS: \(loadError.localizedDescription)")
                        return
                    }
                    do {
                        let startOpts: [String: NSObject] = [
                            "config": config as NSString,
                            "mtu": NSNumber(value: mtu),
                            "proxyOnly": NSNumber(value: proxyOnly),
                        ]
                        if manager.connection.status == .connected || manager.connection.status == .connecting {
                            manager.connection.stopVPNTunnel()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                do {
                                    try manager.connection.startVPNTunnel(options: startOpts)
                                    result(nil)
                                } catch {
                                    result("Не удалось перезапустить туннель iOS: \(error.localizedDescription)")
                                }
                            }
                        } else {
                            try manager.connection.startVPNTunnel(options: startOpts)
                            result(nil)
                        }
                    } catch {
                        result("Не удалось запустить туннель iOS: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func stopVpnTunnel(result: @escaping FlutterResult) {
        if let manager = vpnManager {
            manager.connection.stopVPNTunnel()
            result(nil)
        } else {
            loadExistingVpnManager { manager in
                manager?.connection.stopVPNTunnel()
                result(nil)
            }
        }
    }

    private func queryCurrentStatus(result: @escaping FlutterResult) {
        let respond = { [weak self] (manager: NETunnelProviderManager?) in
            guard let self = self else { return }
            let statusStr = Self.mapVpnStatus(manager?.connection.status ?? .disconnected)
            if statusStr == "disconnected", let session = manager?.connection as? NETunnelProviderSession {
                self.sendExtensionCommand(["cmd": "status"], session: session) { reply in
                    let extErr = (reply?["error"] as? String) ?? self.lastTunnelError
                    if !extErr.isEmpty {
                        self.lastTunnelError = extErr
                    }
                    result([
                        "status": extErr.isEmpty ? statusStr : "failed",
                        "error": extErr,
                        "server": self.currentServerName,
                    ])
                }
            } else {
                result([
                    "status": statusStr,
                    "error": self.lastTunnelError,
                    "server": self.currentServerName,
                ])
            }
        }

        if let manager = vpnManager {
            respond(manager)
        } else {
            loadExistingVpnManager(completion: respond)
        }
    }

    private func queryTrafficStats(result: @escaping FlutterResult) {
        guard let session = vpnManager?.connection as? NETunnelProviderSession,
              session.status == .connected else {
            result("{\"running\":false,\"up\":0,\"down\":0,\"connections\":0}")
            return
        }
        sendExtensionCommand(["cmd": "stats"], session: session) { reply in
            guard let reply = reply,
                  let json = Self.encodeJsonString(reply) else {
                result("{\"running\":true,\"up\":0,\"down\":0,\"connections\":0}")
                return
            }
            result(json)
        }
    }

    private func queryLogs(limit: Int, result: @escaping FlutterResult) {
        if let session = vpnManager?.connection as? NETunnelProviderSession,
           session.status == .connected || session.status == .connecting {
            sendExtensionCommand(["cmd": "logs", "limit": limit], session: session) { [weak self] reply in
                if let lines = reply?["lines"] as? [String], !lines.isEmpty {
                    result(lines)
                } else {
                    result(self?.readLocalLogFile(limit: limit) ?? [])
                }
            }
        } else {
            result(readLocalLogFile(limit: limit))
        }
    }

    private func clearTunnelLogs(result: @escaping FlutterResult) {
        let logURL = workingDirectory.appendingPathComponent("core.log")
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        if let session = vpnManager?.connection as? NETunnelProviderSession,
           session.status == .connected {
            sendExtensionCommand(["cmd": "clearLogs"], session: session) { _ in
                result(true)
            }
        } else {
            result(true)
        }
    }

    @objc private func vpnStatusDidChange(_ notification: Notification) {
        emitCurrentVpnState()
    }

    private func emitCurrentVpnState() {
        guard let sink = eventSink else { return }
        let status = vpnManager?.connection.status ?? .disconnected
        let mapped = Self.mapVpnStatus(status)
        sink([
            "type": "state",
            "status": mapped,
            "error": lastTunnelError,
        ])
    }

    private static func mapVpnStatus(_ status: NEVPNStatus) -> String {
        switch status {
        case .connected:
            return "connected"
        case .connecting, .reasserting:
            return "connecting"
        case .disconnecting:
            return "disconnecting"
        case .disconnected, .invalid:
            return "disconnected"
        @unknown default:
            return "disconnected"
        }
    }

    private func sendExtensionCommand(
        _ payload: [String: Any],
        session: NETunnelProviderSession,
        completion: @escaping ([String: Any]?) -> Void
    ) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(nil)
            return
        }
        do {
            try session.sendProviderMessage(data) { responseData in
                DispatchQueue.main.async {
                    guard let responseData = responseData,
                          let obj = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                        completion(nil)
                        return
                    }
                    completion(obj)
                }
            }
        } catch {
            DispatchQueue.main.async {
                completion(nil)
            }
        }
    }

    private func collectReferencedTrsFiles(from configJson: String) -> [String: Data] {
        var out: [String: Data] = [:]
        guard let data = configJson.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let route = root["route"] as? [String: Any],
              let ruleSets = route["rule_set"] as? [[String: Any]] else {
            return out
        }
        for rs in ruleSets where (rs["type"] as? String) == "local" {
            if let path = rs["path"] as? String,
               FileManager.default.fileExists(atPath: path),
               let fileData = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                let name = URL(fileURLWithPath: path).lastPathComponent
                out[name] = fileData
            }
        }
        return out
    }

    private func readLocalLogFile(limit: Int) -> [String] {
        let logURL = workingDirectory.appendingPathComponent("core.log")
        guard let content = try? String(contentsOf: logURL, encoding: .utf8) else {
            return []
        }
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return lines.count <= limit ? lines : Array(lines.suffix(limit))
    }

    // MARK: - Network Monitor

    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            if path.status != .satisfied {
                self.currentNetworkType = "none"
            } else if path.usesInterfaceType(.wifi) {
                self.currentNetworkType = "wifi"
            } else if path.usesInterfaceType(.cellular) {
                self.currentNetworkType = "cellular"
            } else if path.usesInterfaceType(.wiredEthernet) {
                self.currentNetworkType = "ethernet"
            } else {
                self.currentNetworkType = "wifi"
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    // MARK: - Share Sheet & QR Scanner

    private var activeRootViewController: UIViewController? {
        for scene in UIApplication.shared.connectedScenes {
            if let windowScene = scene as? UIWindowScene {
                for window in windowScene.windows where window.isKeyWindow {
                    return window.rootViewController
                }
                if let first = windowScene.windows.first?.rootViewController {
                    return first
                }
            }
        }
        return window?.rootViewController
    }

    private func presentShareSheet(items: [Any], subject: String) {
        guard let rootVC = activeRootViewController else { return }
        let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if !subject.isEmpty {
            activityVC.setValue(subject, forKey: "subject")
        }
        if let pop = activityVC.popoverPresentationController {
            pop.sourceView = rootVC.view
            pop.sourceRect = CGRect(x: rootVC.view.bounds.midX, y: rootVC.view.bounds.midY, width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
        rootVC.present(activityVC, animated: true)
    }

    private func presentCameraQrScanner(result: @escaping FlutterResult) {
        guard let rootVC = activeRootViewController else {
            result(nil)
            return
        }
        let scannerVC = TachyonQrScannerViewController { scannedValue in
            result(scannedValue)
        }
        scannerVC.modalPresentationStyle = .fullScreen
        rootVC.present(scannerVC, animated: true)
    }

    private func presentGalleryQrPicker(result: @escaping FlutterResult) {
        guard let rootVC = activeRootViewController else {
            result(nil)
            return
        }
        var config = PHPickerConfiguration()
        config.selectionLimit = 1
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        let delegate = TachyonGalleryQrPickerDelegate { scanned in
            result(scanned)
        }
        objc_setAssociatedObject(picker, &TachyonGalleryQrPickerDelegate.assocKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        picker.delegate = delegate
        rootVC.present(picker, animated: true)
    }

    // MARK: - Static Utilities

    private static func consumeCoreLastError() -> String? {
        guard let ptr = tachyon_core_last_error() else { return nil }
        defer { tachyon_core_string_free(ptr) }
        let msg = String(cString: ptr).trimmingCharacters(in: .whitespacesAndNewlines)
        return msg.isEmpty ? nil : msg
    }

    private static func encodeJsonString(_ dict: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Gallery QR Picker Delegate

private final class TachyonGalleryQrPickerDelegate: NSObject, PHPickerViewControllerDelegate {
    static var assocKey: UInt8 = 0
    private let onComplete: (String?) -> Void
    private var completed = false

    init(onComplete: @escaping (String?) -> Void) {
        self.onComplete = onComplete
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !completed else { return }
        completed = true

        guard let provider = results.first?.itemProvider,
              provider.canLoadObject(ofClass: UIImage.self) else {
            onComplete(nil)
            return
        }

        provider.loadObject(ofClass: UIImage.self) { object, _ in
            guard let image = object as? UIImage,
                  let ciImage = CIImage(image: image),
                  let detector = CIDetector(
                      ofType: CIDetectorTypeQRCode,
                      context: nil,
                      options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
                  ) else {
                DispatchQueue.main.async { self.onComplete(nil) }
                return
            }
            let features = detector.features(in: ciImage)
            let qrFeature = features.compactMap { $0 as? CIQRCodeFeature }.first
            let payload = qrFeature?.messageString
            DispatchQueue.main.async {
                self.onComplete(payload)
            }
        }
    }
}

// MARK: - Camera QR Scanner ViewController

private final class TachyonQrScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let onComplete: (String?) -> Void
    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var finished = false

    init(onComplete: @escaping (String?) -> Void) {
        self.onComplete = onComplete
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.04, green: 0.043, blue: 0.05, alpha: 1.0)

        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video),
              let videoInput = try? AVCaptureDeviceInput(device: videoCaptureDevice),
              captureSession.canAddInput(videoInput) else {
            closeWithResult(nil)
            return
        }
        captureSession.addInput(videoInput)

        let metadataOutput = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(metadataOutput) else {
            closeWithResult(nil)
            return
        }
        captureSession.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        metadataOutput.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: captureSession)
        preview.frame = view.layer.bounds
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        self.previewLayer = preview

        let closeButton = UIButton(type: .system)
        closeButton.setTitle("Отмена", for: .normal)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        closeButton.layer.cornerRadius = 10
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        closeButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        view.addSubview(closeButton)

        NSLayoutConstraint.activate([
            closeButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -28),
            closeButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }

    @objc private func cancelTapped() {
        closeWithResult(nil)
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !finished,
              let readableObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let stringValue = readableObject.stringValue,
              !stringValue.isEmpty else {
            return
        }
        AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
        closeWithResult(stringValue)
    }

    private func closeWithResult(_ value: String?) {
        guard !finished else { return }
        finished = true
        if captureSession.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [ captureSession ] in
                captureSession.stopRunning()
            }
        }
        dismiss(animated: true) { [onComplete] in
            onComplete(value)
        }
    }
}
