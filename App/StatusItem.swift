import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The small scissors in the menu bar: the only place with words.
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private weak var notch: NotchController?

    init(notch: NotchController) {
        self.notch = notch
        super.init()
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: "Mane")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Mirror", action: #selector(openMirror), keyEquivalent: "m")
        open.keyEquivalentModifierMask = [.control, .option]
        open.target = self
        menu.addItem(open)
        let key = NSMenuItem(title: "fal.ai API Key…", action: #selector(editKey), keyEquivalent: "")
        key.target = self
        menu.addItem(key)
        let photos = NSMenuItem(title: "Show Saved Photos", action: #selector(showPhotos), keyEquivalent: "")
        photos.target = self
        menu.addItem(photos)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Mane", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
    }

    @objc private func openMirror() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.notch?.open() }
    }

    @objc private func editKey() { KeyWindow.show() }

    @objc private func showPhotos() {
        let dir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mane", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - API key window

@MainActor
enum KeyWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 210),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: KeyView { w.close() })
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct KeyView: View {
    var done: () -> Void
    @State private var key = KeyStore.key ?? ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "scissors").font(.system(size: 20, weight: .light))
                Text("Mane").font(.system(size: 20, weight: .semibold))
            }
            Text("Paste your fal.ai key. It stays on this Mac and is only sent to fal.ai.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("fal.ai key", text: $key)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Link("Get a key", destination: URL(string: "https://fal.ai/dashboard/keys")!)
                    .font(.system(size: 12))
                Spacer()
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 420)
    }

    private func save() {
        KeyStore.save(key)
        done()
    }
}

// MARK: - Global shortcut (⌃⌥M)

enum HotKey {
    private static var action: (() -> Void)?
    private static var ref: EventHotKeyRef?

    static func register(_ handler: @escaping () -> Void) {
        action = handler
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4D41_4E45), id: 1) // "MANE"
        RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(controlKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &ref)
    }
}
