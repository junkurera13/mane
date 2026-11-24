import AppKit
import SwiftUI

// MARK: - The shape

/// A notch: flat top with small outward "ears" where it meets the screen edge,
/// straight sides, rounded bottom corners. Animates between notch and mirror sizes.
struct NotchShape: Shape {
    var ear: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, bottomRadius) }
        set { ear = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let e = min(ear, r.width / 4, r.height / 2)
        let br = min(bottomRadius, (r.width - 2 * e) / 2, r.height - e)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + e, y: r.minY + e), control: CGPoint(x: r.minX + e, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + e, y: r.maxY - br))
        p.addQuadCurve(to: CGPoint(x: r.minX + e + br, y: r.maxY), control: CGPoint(x: r.minX + e, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - e - br, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - e, y: r.maxY - br), control: CGPoint(x: r.maxX - e, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - e, y: r.minY + e))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - e, y: r.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Root

struct NotchRootView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var engine: MirrorEngine
    var onOpen: () -> Void
    var onClose: () -> Void

    var body: some View {
        let g = model.geometry
        let open = model.expanded
        let hover = model.hovering && !open
        let ear: CGFloat = open ? NotchGeometry.ear : 4
        let island = open
            ? g.islandSize
            : CGSize(width: g.notch.width - 8 + (hover ? 16 : 0), height: g.notch.height + (hover ? 4 : 0))

        ZStack(alignment: .top) {
            NotchShape(ear: ear, bottomRadius: open ? 36 : (hover ? 12 : 9))
                .fill(Color.black)
                .frame(width: island.width + ear * 2, height: island.height)
                .shadow(color: .black.opacity(open ? 0.55 : 0), radius: open ? 30 : 0, y: open ? 16 : 0)
                .contentShape(Rectangle())
                .onHover { inside in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { model.hovering = inside }
                }
                .onTapGesture { if !model.expanded { onOpen() } }

            MirrorPanel(
                side: g.mirrorSide,
                styles: engine.allStyles,
                thumbs: engine.thumbs,
                active: engine.active,
                busy: engine.busy,
                failedID: engine.failedID,
                shake: engine.shake,
                cameraDenied: engine.camera == .denied,
                typing: $model.typing,
                onTap: { engine.toggle($0) },
                onCustom: { engine.addCustom($0) }
            ) {
                MirrorHost(engine: engine)
            }
            .padding(.top, g.notch.height + NotchGeometry.gap)
            .opacity(model.showContent ? 1 : 0)
            .scaleEffect(model.showContent ? 1 : 0.94, anchor: .top)
            .allowsHitTesting(model.showContent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct MirrorHost: NSViewRepresentable {
    let engine: MirrorEngine
    func makeNSView(context: Context) -> MirrorContainerView { engine.container }
    func updateNSView(_ view: MirrorContainerView, context: Context) {}
}

// MARK: - The mirror and its circles

struct MirrorPanel<Content: View>: View {
    let side: CGFloat
    let styles: [HairStyle]
    let thumbs: [String: NSImage]
    let active: String?
    let busy: Bool
    let failedID: String?
    let shake: Int
    let cameraDenied: Bool
    @Binding var typing: Bool
    var onTap: (HairStyle) -> Void
    var onCustom: (String) -> Void
    @ViewBuilder var content: () -> Content

    @State private var text = ""

    var body: some View {
        ZStack(alignment: .bottom) {
            content()
                .frame(width: side, height: side)

            if cameraDenied {
                Button {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                } label: {
                    Image(systemName: "video.slash")
                        .font(.system(size: 34, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: side, height: side)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // A soft dark fade behind the circles so they read on any background.
            LinearGradient(colors: [.clear, .black.opacity(0.28)], startPoint: .top, endPoint: .bottom)
                .frame(height: 110)
                .allowsHitTesting(false)

            Group {
                if typing {
                    TypingBar(text: $text, width: side - 48) { value in
                        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { typing = false }
                        text = ""
                        if !v.isEmpty { onCustom(v) }
                    }
                    .transition(.asymmetric(insertion: .scale(scale: 0.6).combined(with: .opacity),
                                            removal: .opacity))
                } else {
                    StyleBar(styles: styles, thumbs: thumbs, active: active, busy: busy,
                             failedID: failedID, shake: shake, width: side - 32,
                             onTap: onTap,
                             onPlus: { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { typing = true } })
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .padding(.bottom, 18)
            .opacity(cameraDenied ? 0 : 1)
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

struct StyleBar: View {
    let styles: [HairStyle]
    let thumbs: [String: NSImage]
    let active: String?
    let busy: Bool
    let failedID: String?
    let shake: Int
    let width: CGFloat
    var onTap: (HairStyle) -> Void
    var onPlus: () -> Void

    var body: some View {
        let spacing: CGFloat = 10
        let n = CGFloat(styles.count + 1)
        let d = min(46, ((width - spacing * (n - 1)) / n).rounded(.down))
        HStack(spacing: spacing) {
            ForEach(styles) { style in
                StyleCircle(style: style, thumb: thumbs[style.id], diameter: d,
                            isActive: active == style.id,
                            isBusy: busy && active == style.id,
                            shake: failedID == style.id ? shake : 0)
                    .onTapGesture { onTap(style) }
            }
            PlusCircle(diameter: d).onTapGesture(perform: onPlus)
        }
        .padding(.vertical, 6)   // room for the active circle to grow
    }
}

struct StyleCircle: View {
    let style: HairStyle
    let thumb: NSImage?
    let diameter: CGFloat
    let isActive: Bool
    let isBusy: Bool
    let shake: Int

    var body: some View {
        ZStack {
            if let thumb {
                Image(nsImage: thumb).resizable().interpolation(.high).scaledToFill()
            } else if let icon = style.icon {
                Image(nsImage: icon).resizable().interpolation(.high).scaledToFill()
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: diameter * 0.36, weight: .light))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .glassCircle()
        .overlay(
            Circle().strokeBorder(.white.opacity(isActive ? 0.95 : 0.22), lineWidth: isActive ? 2 : 0.75)
        )
        .overlay {
            if isBusy { SpinnerRing().padding(-4) }
        }
        .scaleEffect(isActive ? 1.12 : 1)
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .modifier(Shake(travel: 6, animatableData: CGFloat(shake)))
        .animation(.spring(response: 0.32, dampingFraction: 0.6), value: isActive)
        .animation(.linear(duration: 0.45), value: shake)
        .contentShape(Circle())
        .help(style.isCustom ? style.look : "")
    }
}

struct PlusCircle: View {
    let diameter: CGFloat
    var body: some View {
        Image(systemName: "plus")
            .font(.system(size: diameter * 0.38, weight: .light))
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .glassCircle()
            .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            .contentShape(Circle())
    }
}

struct TypingBar: View {
    @Binding var text: String
    let width: CGFloat
    var onSubmit: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "scissors")
                .font(.system(size: 14, weight: .light))
                .foregroundStyle(.white.opacity(0.6))
            TextField("", text: $text, prompt: Text("any haircut…").foregroundColor(.white.opacity(0.45)))
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .focused($focused)
                .onSubmit { onSubmit(text) }
        }
        .padding(.horizontal, 18)
        .frame(width: width, height: 46)
        .glassCapsule()
        .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

/// A thin white arc going round while a cut is on its way.
struct SpinnerRing: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees((t * 400).truncatingRemainder(dividingBy: 360)))
        }
    }
}

struct Shake: GeometryEffect {
    var travel: CGFloat
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(animatableData * .pi * 4), y: 0))
    }
}

extension View {
    /// Liquid Glass on macOS 26+, frosted material before that.
    @ViewBuilder func glassCircle() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: Circle())
        } else {
            self.background(.ultraThinMaterial, in: Circle())
        }
        #else
        self.background(.ultraThinMaterial, in: Circle())
        #endif
    }

    @ViewBuilder func glassCapsule() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: Capsule())
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
        #else
        self.background(.ultraThinMaterial, in: Capsule())
        #endif
    }
}
