import AppKit
import AVFoundation
import WebKit

/// Owns the mirror: a WKWebView running web/mirror.html (camera + live AI video over
/// WebRTC through fal: Eden Live first, Lucy second), plus the circles' state.
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
    private var queued: [(String, String)] = []
    private var minting = false
    private var nativeCam: NativeCamera?
    private var isOpen = false

    // "You with the cut" frames that anchor Eden Live, made by Nano Banana from your camera.
    // Kept for one opening of the mirror; the first tap makes one, then the rest are made in
    // the background so later taps switch in about two seconds.
    private var anchors: [String: String] = [:]          // style id -> small JPEG data URL
    private var anchorQueue: [HairStyle] = []
    private var anchorInFlight: Set<String> = []
    private var anchorJobs = 0
    private var prefetchStarted = false
    private var generation = 0                           // bumps on open/close; stale work is dropped
    private let maxAnchorJobs = 1                        // the live session uses one of fal's slots

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
        let ucc = wv.configuration.userContentController
        ucc.add(WeakHandler(self), name: "mane")
        ucc.addScriptMessageHandler(FalBridge(), contentWorld: .page, name: "maneFetch")
        // fal's realtime client (web/vendor/fal-realtime.js) → window.FalRealtime
        if let url = Bundle.main.url(forResource: "fal-realtime", withExtension: "js", subdirectory: "web/vendor"),
           let js = try? String(contentsOf: url, encoding: .utf8) {
            ucc.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        } else {
            NSLog("Mane: fal-realtime.js is missing from the app bundle")
        }
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
        resetAnchors()
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
        resetAnchors()
        call("close")
        nativeCam?.stop()
        if camera == .on { camera = .off }
    }

    // MARK: - Choosing a haircut

    func toggle(_ style: HairStyle) {
        guard camera == .on else { return }
        guard KeyStore.key != nil else { onNeedsKey?(); return }
        if active == style.id { revert(); return }
        guard nativeCam == nil, demoImage == nil else { return }   // live needs WebKit's camera
        active = style.id
        failedID = nil
        busy = true
        if let anchor = anchors[style.id] {
            applyLive(style, anchor: anchor)
        } else {
            call("warm")                      // open the live session while the anchor is made
            requestAnchor(style, urgent: true)
        }
    }

    private func applyLive(_ style: HairStyle, anchor: String?) {
        var prompts: [String: Any] = ["eden": style.edenPrompt, "lucy": style.livePrompt]
        if let anchor { prompts["anchor"] = anchor }
        call("apply", style.id, prompts)
    }

    // MARK: - Anchors

    private func resetAnchors() {
        generation += 1
        anchors.removeAll()
        anchorQueue.removeAll()
        anchorInFlight.removeAll()
        anchorJobs = 0
        prefetchStarted = false
    }

    private func requestAnchor(_ style: HairStyle, urgent: Bool) {
        guard anchors[style.id] == nil, !anchorInFlight.contains(style.id) else { return }
        anchorQueue.removeAll { $0.id == style.id }
        if urgent { anchorQueue.insert(style, at: 0) } else { anchorQueue.append(style) }
        pumpAnchors()
    }

    private func pumpAnchors() {
        guard let key = KeyStore.key else { return }
        while anchorJobs < maxAnchorJobs, !anchorQueue.isEmpty {
            let style = anchorQueue.removeFirst()
            if anchors[style.id] != nil || anchorInFlight.contains(style.id) { continue }
            anchorJobs += 1
            anchorInFlight.insert(style.id)
            let gen = generation
            Task {
                var made: String?
                do {
                    guard let frame = await self.cameraFrame() else {
                        throw FalClient.Failure(status: 0, detail: "no camera frame")
                    }
                    let jpeg = try await FalClient.editPhoto(key: key, imageDataURL: frame,
                                                             prompt: style.anchorPrompt, aspectRatio: "16:9")
                    if gen == self.generation, let small = Self.anchorJPEG(jpeg) {
                        made = "data:image/jpeg;base64," + small.base64EncodedString()
                    }
                    if let t = ThumbStore.save(style.id, jpeg: jpeg, mirrored: true) { self.thumbs[style.id] = t }
                } catch {
                    NSLog("Mane: anchor for \(style.id) failed: \(error)")
                }
                guard gen == self.generation else { return }
                self.anchorJobs -= 1
                self.anchorInFlight.remove(style.id)
                if let made { self.anchors[style.id] = made }
                // The cut you're waiting for: go live with it (without an anchor if making one
                // failed; Eden then makes its own, and Lucy never needs one).
                if self.active == style.id { self.applyLive(style, anchor: made) }
                if made != nil { self.startPrefetch() }
                self.pumpAnchors()
            }
        }
    }

    /// After the first cut, make the other built-in cuts' anchors in the background.
    private func startPrefetch() {
        guard !prefetchStarted else { return }
        prefetchStarted = true
        for style in HairStyle.builtIn where anchors[style.id] == nil { requestAnchor(style, urgent: false) }
    }

    private func cameraFrame() async -> String? {
        guard loaded else { return nil }
        let r = try? await webView.callAsyncJavaScript("return mane.frame(896, 0.85)", arguments: [:],
                                                       in: nil, contentWorld: .page)
        return r as? String
    }

    /// Eden takes the anchor as a data URL under ~45 KB.
    static func anchorJPEG(_ jpeg: Data) -> Data? {
        guard let src = NSImage(data: jpeg), let rep0 = src.representations.first else { return nil }
        let w0 = CGFloat(rep0.pixelsWide), h0 = CGFloat(rep0.pixelsHigh)
        guard w0 > 0, h0 > 0 else { return nil }
        let w = min(640, w0), h = (h0 * w / w0).rounded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w), pixelsHigh: Int(h),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        src.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        for q in [0.8, 0.7, 0.6, 0.5, 0.4] {
            if let d = rep.representation(using: .jpeg, properties: [.compressionFactor: q]), d.count < 44_000 { return d }
        }
        return nil
    }

    func revert() {
        active = nil
        busy = false
        call("apply", NSNull(), NSNull())
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

    /// Demo/screenshot mode: pretend a cut was chosen (optionally showing a finished photo).
    func demoSelect(_ id: String, still: NSImage?) {
        guard let style = allStyles.first(where: { $0.id == id }) else { return }
        active = style.id
        if let still {
            busy = false
            call("showStill", Self.dataURL(still))
        } else {
            busy = true
        }
    }

    /// `--probe`: report what this Mac's WebKit offers the mirror (camera, WebRTC, sockets).
    func probe(_ done: @escaping (String) -> Void) {
        let script = """
        const out = { secure: isSecureContext, mediaDevices: !!navigator.mediaDevices,
                      getUserMedia: !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia),
                      rtc: typeof RTCPeerConnection, ws: typeof WebSocket, ua: navigator.userAgent };
        const race = (p, ms) => Promise.race([p, new Promise((r) => setTimeout(() => r("timeout"), ms))]);
        try {
          const pc = new RTCPeerConnection({ iceServers: [{ urls: "stun:stun.l.google.com:19302" }] });
          pc.addTransceiver("video");
          const o = await pc.createOffer();
          out.offer = o.sdp.length; out.h264 = /H264/.test(o.sdp); out.vp8 = /VP8/.test(o.sdp);
          pc.close();
        } catch (e) { out.rtcError = String(e); }
        try {
          out.devices = (await race(navigator.mediaDevices.enumerateDevices(), 4000));
          if (Array.isArray(out.devices)) out.devices = out.devices.map((d) => d.kind);
        } catch (e) { out.devices = String(e); }
        try {
          out.camera = await race(navigator.mediaDevices.getUserMedia({ video: true }).then((s) => {
            s.getTracks().forEach((t) => t.stop()); return "ok"; }), 6000);
        } catch (e) { out.camera = e.name + ": " + e.message; }
        try {
          out.socket = await race(new Promise((r) => {
            const ws = new WebSocket("wss://fal.run/decart/lucy-2-6/realtime?fal_jwt_token=probe");
            ws.binaryType = "arraybuffer";
            ws.onopen = () => { r("open"); ws.close(); };
            ws.onerror = () => r("error");
            ws.onclose = (e) => r("closed " + e.code);
          }), 8000);
        } catch (e) { out.socket = String(e); }
        return JSON.stringify(out);
        """
        Task {
            for _ in 0..<50 where !self.loaded { try? await Task.sleep(nanoseconds: 100_000_000) }
            do {
                let r = try await self.webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
                done(r as? String ?? "\(String(describing: r))")
            } catch {
                done("probe failed: \(error)")
            }
        }
    }

    /// A live session couldn't start: shake the circle and go back to your real hair.
    private func fail(_ id: String, reason: String) {
        NSLog("Mane: live failed for \(id): \(reason)")
        busy = false
        active = nil
        failedID = id
        shake += 1
        call("apply", NSNull(), NSNull())
        if reason.range(of: "unauthori|balance|locked|401|403|invalid key", options: [.regularExpression, .caseInsensitive]) != nil {
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
        let code = "window.mane && mane.\(fn).apply(null, \(json)); undefined;"
        if loaded { run(code, fn) } else { queued.append((code, fn)) }
    }

    private func run(_ code: String, _ fn: String) {
        if Self.debug { NSLog("Mane → js \(fn) (\(code.count) chars)") }
        webView.evaluateJavaScript(code) { _, error in
            if let error { NSLog("Mane: js \(fn) failed: \(error)") }
        }
    }

    private func pageLoaded() {
        guard !loaded else { return }
        loaded = true
        let pending = queued
        queued.removeAll()
        for (code, fn) in pending { run(code, fn) }
    }

    static let debug = ProcessInfo.processInfo.environment["MANE_DEBUG"] != nil
        || CommandLine.arguments.contains("--demo")

    /// Demo mode: print what the page is showing (for CI logs).
    func dumpState() {
        webView.evaluateJavaScript(
            "JSON.stringify(Object.assign(mane.state(), {stillSrc: document.getElementById('still').src.length, " +
            "body: document.body.className, log: mane.log().map(x => x.type).join(',')}))"
        ) { result, error in
            NSLog("Mane state: \(result ?? "nil") \(error.map { "\($0)" } ?? "")")
        }
    }

    fileprivate func receive(_ body: Any) {
        guard let m = body as? [String: Any], let type = m["type"] as? String else { return }
        if Self.debug { NSLog("Mane ← js \(m.filter { $0.key != "detail" })") }
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

        case "showing":
            // The live video now shows this cut.
            guard let id = m["id"] as? String, id == active else { return }
            busy = false
            // Grab your face with the new cut for the circle, once it has settled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.captureLiveThumb(id)
            }

        case "failed":
            guard let id = m["id"] as? String else { return }
            if active == id { fail(id, reason: m["reason"] as? String ?? "") }

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
            }
        }
    }

    private func captureLiveThumb(_ id: String) {
        guard active == id, anchors[id] == nil else { return }
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

/// The page's fal client makes its HTTP calls (session setup, heartbeats) through here, so the
/// key is added natively and never enters the web page. Only fal's own hosts are allowed.
final class FalBridge: NSObject, WKScriptMessageHandlerWithReply {
    private static let allowedHosts: Set<String> = ["wma.fal.run", "rest.fal.ai", "fal.run", "queue.fal.run"]

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let req = message.body as? [String: Any],
              let urlString = req["url"] as? String, let url = URL(string: urlString),
              url.scheme == "https", let host = url.host, Self.allowedHosts.contains(host)
        else { replyHandler(nil, "blocked request"); return }
        guard let key = KeyStore.key else { replyHandler(nil, "no fal key"); return }
        var r = URLRequest(url: url, timeoutInterval: 120)
        r.httpMethod = (req["method"] as? String) ?? "GET"
        for (name, value) in (req["headers"] as? [String: String]) ?? [:] where name.lowercased() != "authorization" {
            r.setValue(value, forHTTPHeaderField: name)
        }
        r.setValue("Key " + key, forHTTPHeaderField: "Authorization")
        if let body = req["body"] as? String { r.httpBody = Data(body.utf8) }
        URLSession.shared.dataTask(with: r) { data, response, error in
            let http = response as? HTTPURLResponse
            let reply: [String: Any] = [
                "status": http?.statusCode ?? 599,
                "body": data.flatMap { String(data: $0, encoding: .utf8) } ?? (error.map { "\($0)" } ?? ""),
                "contentType": http?.value(forHTTPHeaderField: "Content-Type") ?? "application/json",
            ]
            DispatchQueue.main.async { replyHandler(reply, nil) }
        }.resume()
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
