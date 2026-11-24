import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notch: NotchController?
    private var status: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments

        // `Mane --render <dir>`: draw the UI to PNGs and quit (used by CI to check the layout).
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            PreviewRenderer.renderAll(to: URL(fileURLWithPath: args[i + 1]))
            NSApp.terminate(nil)
            return
        }

        let engine = MirrorEngine()
        let notch = NotchController(engine: engine)
        self.notch = notch
        status = StatusItemController(notch: notch)
        engine.onNeedsKey = { KeyWindow.show() }

        HotKey.register { [weak notch] in notch?.toggle() }

        func arg(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        // `Mane --probe`: print what WebKit offers (camera, WebRTC, sockets) and quit.
        if args.contains("--probe") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { notch.open() }
            engine.probe { result in
                print("PROBE " + result)
                fflush(stdout)
                NSApp.terminate(nil)
            }
            return
        }

        // `Mane --demo <image> [--demo-style id [--demo-still img]] [--demo-typing]`:
        // open the mirror on a picture instead of the camera (for screenshots).
        if let path = arg("--demo"), let image = NSImage(contentsOfFile: path) {
            engine.demoImage = image
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { notch.open() }
            if let id = arg("--demo-style") {
                let still = arg("--demo-still").flatMap { NSImage(contentsOfFile: $0) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { engine.demoSelect(id, still: still) }
            }
            if args.contains("--demo-typing") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { notch.model.typing = true }
            }
            return
        }

        if KeyStore.key == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { KeyWindow.show() }
        }
    }
}
