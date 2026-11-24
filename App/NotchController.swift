import AppKit
import SwiftUI

/// Where the notch is and how big the mirror should be on this screen.
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var hasNotch: Bool
    var notch: CGSize        // the hardware notch (or a matching pill on screens without one)
    var notchCenterX: CGFloat
    var mirrorSide: CGFloat

    static let rim: CGFloat = 10            // black border around the mirror
    static let gap: CGFloat = 6             // between the notch and the mirror
    static let shadowPad: CGFloat = 36      // room for the shadow inside the window
    static let ear: CGFloat = 14            // the outward curves where it meets the top edge

    /// The black shape when open: notch on top, mirror below.
    var islandSize: CGSize {
        CGSize(width: mirrorSide + Self.rim * 2, height: notch.height + Self.gap + mirrorSide + Self.rim)
    }

    static func current() -> NotchGeometry {
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens[0]
        let f = screen.frame
        let side = (min(f.height * 0.66, 640) / 2).rounded() * 2
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let w = right.minX - left.maxX
            return NotchGeometry(screenFrame: f, hasNotch: true,
                                 notch: CGSize(width: w, height: screen.safeAreaInsets.top),
                                 notchCenterX: left.maxX + w / 2, mirrorSide: max(side, 420))
        }
        let menuBar = max(f.maxY - screen.visibleFrame.maxY, 24)
        return NotchGeometry(screenFrame: f, hasNotch: false,
                             notch: CGSize(width: 180, height: min(menuBar, 32)),
                             notchCenterX: f.midX, mirrorSide: max(side, 420))
    }
}

@MainActor
final class NotchModel: ObservableObject {
    @Published var geometry = NotchGeometry.current()
    @Published var expanded = false
    @Published var showContent = false
    @Published var hovering = false
    @Published var typing = false
}

/// A borderless panel that sits over the notch, above the menu bar.
final class NotchPanel: NSPanel {
    static func make() -> NotchPanel {
        let p = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        p.configure()
        return p
    }

    private func configure() {
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click on the (non-activating) panel count.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class NotchController: NSObject {
    let model = NotchModel()
    let engine: MirrorEngine
    private let panel = NotchPanel.make()
    private var monitors: [Any] = []
    private var collapseWork: DispatchWorkItem?

    init(engine: MirrorEngine) {
        self.engine = engine
        super.init()
        let root = NotchRootView(model: model, engine: engine,
                                 onOpen: { [weak self] in self?.open() },
                                 onClose: { [weak self] in self?.close() })
        let host = FirstClickHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host
        place(expanded: false)
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.geometry = NotchGeometry.current()
                self.place(expanded: self.model.expanded)
            }
        }
    }

    var isOpen: Bool { model.expanded }

    func toggle() { model.expanded ? close() : open() }

    func open() {
        guard !model.expanded else { return }
        collapseWork?.cancel()
        model.geometry = NotchGeometry.current()
        place(expanded: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) { model.expanded = true }
        withAnimation(.easeOut(duration: 0.3).delay(0.16)) { model.showContent = true }
        engine.open()
        installMonitors()
    }

    func close() {
        guard model.expanded else { return }
        removeMonitors()
        engine.close()
        model.typing = false
        withAnimation(.easeIn(duration: 0.12)) { model.showContent = false }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.9).delay(0.06)) { model.expanded = false }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.model.expanded else { return }
            self.place(expanded: false)
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
    }

    /// The window is only as big as it needs to be, so it never blocks clicks it shouldn't.
    private func place(expanded: Bool) {
        let g = model.geometry
        let size: CGSize
        if expanded {
            size = CGSize(width: g.islandSize.width + NotchGeometry.ear * 2 + NotchGeometry.shadowPad * 2,
                          height: g.islandSize.height + NotchGeometry.shadowPad * 1.5)
        } else {
            size = CGSize(width: g.notch.width + 24, height: g.notch.height + 6)
        }
        let frame = NSRect(x: g.notchCenterX - size.width / 2, y: g.screenFrame.maxY - size.height,
                           width: size.width, height: size.height)
        panel.setFrame(frame.integral, display: true)
    }

    private func installMonitors() {
        removeMonitors()
        // Click anywhere else: close.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { monitors.append(m) }
        // Esc closes (or leaves the text box), ⌘S saves a photo.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.model.expanded else { return event }
                if event.keyCode == 53 {
                    if self.model.typing { withAnimation(.spring(response: 0.3)) { self.model.typing = false } }
                    else { self.close() }
                    return nil
                }
                if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "s" {
                    self.engine.savePhoto()
                    return nil
                }
                return event
            }
        }) { monitors.append(m) }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }
}
