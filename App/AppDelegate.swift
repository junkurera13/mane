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

        // `Mane --demo <image>`: open the mirror on a picture instead of the camera.
        if let i = args.firstIndex(of: "--demo"), i + 1 < args.count,
           let image = NSImage(contentsOfFile: args[i + 1]) {
            engine.demoImage = image
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { notch.open() }
            if let j = args.firstIndex(of: "--demo-style"), j + 1 < args.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { engine.demoSelect(args[j + 1]) }
            }
            return
        }

        if KeyStore.key == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { KeyWindow.show() }
        }
    }
}
