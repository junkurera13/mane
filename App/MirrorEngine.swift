import AppKit
import AVFoundation
import WebKit

/// Owns the mirror: a WKWebView running web/mirror.html (camera + live AI video over
/// WebRTC), plus the photo fallback and the circles' state.
@MainActor
final class MirrorEngine: NSObject, ObservableObject {
    enum Camera { case off, on, denied }

    @Published private(set) var active: String?          // the haircut showing (nil = your real hair)
    @Published private(set) var busy = false             // a cut is on its way
    @Published private(set) var thumbs: [String: NSImage] = [:]
    @Published private(set) var camera: Camera = .off
    @Published private(set) var shake = 0                // bumps when a try fails
    @Published private(set) var failedID: String?
    @Published private(set) var customStyles: [HairStyle] = CustomStore.load()

    var allStyles: [HairStyle] { HairStyle.builtIn + customStyles }
    var onNeedsKey: (() -> Void)?
    var demoImage: NSImage?

    let webView: WKWebView
    let container = MirrorContainerView()

    private var loaded = false
    private var queued: [String] = []
    private var minting = false
    private var liveBlockedUntil: Date?
    private var stills: [String: String] = [:]           // photo results for this opening
    private var photoInFlight: Set<String> = []
    private var nativeCam: NativeCamera?
    private var isOpen = false

    override init() {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.suppressesIncrementalRendering = false
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.setValue(false, forKey: "drawsBackground")
        wv.allowsMagnification = false
        wv.allowsBackForwardNavigationGestures = false
        webView = wv
        super.init()
        wv.configuration.userContentController.add(WeakHandler(self), name: "mane")
        wv.uiDelegate = self
        wv.navigationDelegate = self
        container.install(webView: wv)
        thumbs = ThumbStore.loadAll(ids: allStyles.map(\.id))
        loadPage()
    }

    private func loadPage() {
        guard let url = Bundle.main.url(forResource: "mirror", withExtension: "html", subdirectory: "web")
                ?? Bundle.main.url(forResource: "mirror", withExtension: "html"),
              let html = try? String(contentsOf: url, encoding: .utf8)
        else {
            NSLog("Mane: mirror.html is missing from the app bundle")
            return
        }
        // An https base URL makes the page a secure context, which getUserMedia needs.
        webView.loadHTMLString(html, baseURL: URL(string: "https://mirror.mane.app/"))
    }

    // MARK: - Opening and closing

    func open() {
        isOpen = true
        stills.removeAll()
        if let demo = demoImage {
            camera = .on
            call("demo", Self.dataURL(demo))
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    guard self.isOpen else { return }
                    if granted { self.startCamera() } else { self.camera = .denied }
                }
            }
        default:
            camera = .denied
        }
    }

    private func startCamera() {
        if let cam = nativeCam { cam.start(); camera = .on } else { call("open") }
    }

    func close() {
        isOpen = false
        active = nil
        busy = false
        stills.removeAll()
        call("close")
        nativeCam?.stop()
        if camera == .on { camera = .off }
    }

    // MARK: - Choosing a haircut

    func toggle(_ style: HairStyle) {
        guard camera == .on else { return }
        guard KeyStore.key != nil else { onNeedsKey?(); return }
        if active == style.id { revert(); return }
        active = style.id
        failedID = nil
        if let still = stills[style.id] {
            busy = false
            call("apply", NSNull(), NSNull())
            call("showStill", still)
            return
        }
        if useLive {
            busy = true
            call("hideStill")
            call("apply", style.id, style.livePrompt)
        } else {
            call("apply", NSNull(), NSNull())
            startPhoto(style)
        }
    }

    func revert() {
        active = nil
        busy = false
        call("busy", false)
        call("apply", NSNull(), NSNull())
        call("hideStill")
    }

    func addCustom(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let style = HairStyle.custom(t)
        var list = customStyles + [style]
        while list.count > CustomStore.limit {
            let dropped = list.removeFirst()
            ThumbStore.remove(dropped.id)
            thumbs[dropped.id] = nil
        }
        customStyles = list
        CustomStore.save(list)
        toggle(style)
    }

    func demoSelect(_ id: String) {
        guard let style = allStyles.first(where: { $0.id == id }) else { return }
        active = style.id
    }

    private var useLive: Bool {
        guard nativeCam == nil, demoImage == nil else { return false }
        if let until = liveBlockedUntil, until > Date() { return false }
        return true
    }

    // MARK: - Photo fallback

    private func startPhoto(_ style: HairStyle) {
        guard let key = KeyStore.key else { onNeedsKey?(); return }
        busy = true
        call("busy", true)
        guard !photoInFlight.contains(style.id) else { return }
        photoInFlight.insert(style.id)
        Task {
            defer { self.photoInFlight.remove(style.id) }
            do {
                guard let shot = await self.snapshot(size: 768, source: "cam") else {
                    throw FalClient.Failure(status: 0, detail: "no camera frame")
                }
                let jpeg = try await FalClient.editPhoto(key: key, imageDataURL: shot, prompt: style.photoPrompt)
                let url = "data:image/jpeg;base64," + jpeg.base64EncodedString()
                if let t = ThumbStore.save(style.id, jpeg: jpeg) { self.thumbs[style.id] = t }
                guard self.isOpen else { return }
                self.stills[style.id] = url
                if self.active == style.id {
                    self.busy = false
                    self.call("busy", false)
                    self.call("showStill", url)
                }
            } catch {
                NSLog("Mane: photo failed: \(error)")
                if self.active == style.id { self.fail(style.id, error) }
            }
        }
    }

    private func fail(_ id: String, _ error: Error) {
        busy = false
        active = nil
        failedID = id
        shake += 1
        call("busy", false)
        call("apply", NSNull(), NSNull())
        call("hideStill")
        if let f = error as? FalClient.Failure, f.isAccountProblem {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.onNeedsKey?() }
        }
    }

    // MARK: - Saving a photo (⌘S)

    func savePhoto() {
        Task {
            guard let dataURL = await snapshot(size: 0, source: "screen"),
                  let comma = dataURL.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
            else { return }
            let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Mane", isDirectory: true)
            try? FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            var name = "Mane " + f.string(from: Date())
            if let id = active { name += " (" + id + ")" }
            name += ".jpg"
            try? data.write(to: pictures.appendingPathComponent(name))
            call("flash")
        }
    }

    // MARK: - Snapshots

    /// A square JPEG data: URL of the mirror. source: "cam", "ai" or "screen".
    func snapshot(size: Int, source: String) async -> String? {
        if let cam = nativeCam, source == "cam" || (source == "screen" && active == nil) {
            return cam.snapshotDataURL(size: size)
        }
        guard loaded else { return nil }
        let result = try? await webView.callAsyncJavaScript(
            "return mane.snapshot(size, 0.9, source)",
            arguments: ["size": size, "source": source], in: nil, contentWorld: .page)
        return result as? String
    }

    // MARK: - Talking to the page

    private func call(_ fn: String, _ args: Any...) {
        let json = (try? JSONSerialization.data(withJSONObject: args, options: [.fragmentsAllowed]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let code = "window.mane && mane.\(fn).apply(null, \(json));"
        if loaded { webView.evaluateJavaScript(code, completionHandler: nil) } else { queued.append(code) }
    }

    private func pageLoaded() {
        guard !loaded else { return }
        loaded = true
        let pending = queued
        queued.removeAll()
        for code in pending { webView.evaluateJavaScript(code, completionHandler: nil) }
    }

    fileprivate func receive(_ body: Any) {
        guard let m = body as? [String: Any], let type = m["type"] as? String else { return }
        #if DEBUG
        NSLog("Mane js: \(m)")
        #endif
        switch type {
        case "loaded":
            pageLoaded()

        case "needToken":
            mintToken()

        case "camera":
            if m["on"] as? Bool == true {
                camera = isOpen ? .on : .off
            } else {
                cameraFailed(m["error"] as? String ?? "")
            }

        case "session":
            let state = m["state"] as? String ?? ""
            if state == "frames", let id = active {
                // Grab your face with the new cut for the circle, once it has settled.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    self?.captureLiveThumb(id)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    if self?.active == id { self?.busy = false }
                }
            }

        case "failed":
            guard let id = m["id"] as? String else { return }
            let reason = m["reason"] as? String ?? ""
            NSLog("Mane: live session failed (\(reason)); using the photo fallback")
            // Don't keep knocking on a door that says it's full.
            liveBlockedUntil = Date().addingTimeInterval(m["fatal"] as? Bool == true ? 300 : 60)
            if active == id, let style = allStyles.first(where: { $0.id == id }) { startPhoto(style) }

        case "timeout":
            active = nil
            busy = false

        default:
            break
        }
    }

    private func mintToken() {
        guard !minting, let key = KeyStore.key, demoImage == nil else { return }
        minting = true
        Task {
            defer { self.minting = false }
            do {
                let token = try await FalClient.realtimeToken(key: key)
                self.call("setToken", token)
            } catch {
                NSLog("Mane: token failed: \(error)")
                self.call("tokenFailed", "\(error)")
                if let f = error as? FalClient.Failure, f.isAccountProblem, let id = self.active {
                    self.fail(id, f)
                }
            }
        }
    }

    private func captureLiveThumb(_ id: String) {
        guard active == id else { return }
        Task {
            guard let url = await snapshot(size: 288, source: "ai"),
                  let comma = url.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(url[url.index(after: comma)...]))
            else { return }
            if let t = ThumbStore.save(id, jpeg: data) { thumbs[id] = t }
        }
    }

    /// WebKit couldn't open the camera. If macOS says we're allowed, show the camera
    /// natively instead (the live stream then isn't possible, so cuts come as photos).
    private func cameraFailed(_ error: String) {
        NSLog("Mane: web camera failed: \(error)")
        guard isOpen else { return }
        if AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
            camera = .denied
            return
        }
        if nativeCam == nil {
            let cam = NativeCamera()
            nativeCam = cam
            container.install(preview: cam.previewLayer)
            call("nativeCamera", true)
        }
        nativeCam?.start()
        camera = .on
    }

    static func dataURL(_ image: NSImage) -> String {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        else { return "" }
        return "data:image/jpeg;base64," + jpg.base64EncodedString()
    }
}

// MARK: - WebKit delegates

extension MirrorEngine: WKUIDelegate, WKNavigationDelegate {
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)   // macOS has already asked you about the camera
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded = false
        loadPage()
        if isOpen { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.open() } }
    }
}

/// Avoids WKUserContentController holding the engine strongly.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var engine: MirrorEngine?
    init(_ engine: MirrorEngine) { self.engine = engine }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { engine?.receive(body) }
    }
}

/// Holds the web view (and, if needed, a native camera layer underneath it).
final class MirrorContainerView: NSView {
    private var previewLayer: CALayer?
    private weak var webView: WKWebView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func install(webView: WKWebView) {
        self.webView = webView
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
    }

    func install(preview: CALayer) {
        previewLayer = preview
        preview.frame = bounds
        layer?.insertSublayer(preview, at: 0)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer?.frame = bounds
        CATransaction.commit()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// AVFoundation camera, used only if WebKit can't open the camera itself.
final class NativeCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let previewLayer: AVCaptureVideoPreviewLayer
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "mane.camera")
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var configured = false
    private let ciContext = CIContext()

    override init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        super.init()
    }

    func start() {
        queue.async { [self] in
            if !configured { configure() }
            if !session.isRunning { session.startRunning() }
            DispatchQueue.main.async {
                if let c = self.previewLayer.connection, c.isVideoMirroringSupported {
                    c.automaticallyAdjustsVideoMirroring = false
                    c.isVideoMirrored = true
                }
            }
        }
    }

    func stop() {
        queue.async { [self] in if session.isRunning { session.stopRunning() } }
    }

    private func configure() {
        configured = true
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        if let device = AVCaptureDevice.default(for: .video),
           let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
        }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock(); latest = pb; lock.unlock()
    }

    /// Square, mirrored JPEG of the latest frame (size 0 = full resolution).
    func snapshotDataURL(size: Int) -> String? {
        lock.lock(); let pb = latest; lock.unlock()
        guard let pb else { return nil }
        var img = CIImage(cvPixelBuffer: pb)
        let e = img.extent, side = min(e.width, e.height)
        img = img.cropped(to: CGRect(x: e.midX - side / 2, y: e.midY - side / 2, width: side, height: side))
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        img = img.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -side, y: 0))
        if size > 0 {
            let s = CGFloat(size) / side
            img = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let data = ciContext.jpegRepresentation(of: img, colorSpace: cs, options: [:])
        else { return nil }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }
}
