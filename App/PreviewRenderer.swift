import AppKit
import SwiftUI

/// `Mane --render <dir> [--face img] [--thumbs dir]`: draws the main states of the UI to
/// PNGs without a camera, so the layout can be checked on a build machine.
@MainActor
enum PreviewRenderer {
    static func renderAll(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let args = CommandLine.arguments
        func arg(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let face = arg("--face").flatMap { NSImage(contentsOfFile: $0) }
        var thumbs: [String: NSImage] = [:]
        if let tdir = arg("--thumbs") {
            for s in HairStyle.builtIn {
                if let img = NSImage(contentsOfFile: tdir + "/" + s.id + ".jpg") { thumbs[s.id] = img }
            }
        }
        let side: CGFloat = 600
        let notch = CGSize(width: 185, height: 32)

        func scene(active: String?, busy: Bool, typing: Bool, thumbs: [String: NSImage], custom: [HairStyle] = []) -> some View {
            let island = CGSize(width: side + NotchGeometry.rim * 2,
                                height: notch.height + NotchGeometry.gap + side + NotchGeometry.rim)
            return ZStack(alignment: .top) {
                LinearGradient(colors: [Color(white: 0.82), Color(white: 0.66)], startPoint: .top, endPoint: .bottom)
                NotchShape(ear: NotchGeometry.ear, bottomRadius: 36)
                    .fill(Color.black)
                    .frame(width: island.width + NotchGeometry.ear * 2, height: island.height)
                    .shadow(color: .black.opacity(0.55), radius: 30, y: 16)
                MirrorPanel(side: side, styles: HairStyle.builtIn + custom, thumbs: thumbs, active: active,
                            busy: busy, failedID: nil, shake: 0, cameraDenied: false,
                            typing: .constant(typing), onTap: { _ in }, onCustom: { _ in }) {
                    ZStack {
                        Color(white: 0.15)
                        if let face { Image(nsImage: face).resizable().scaledToFill() }
                    }
                }
                .padding(.top, notch.height + NotchGeometry.gap)
            }
            .frame(width: island.width + 160, height: island.height + 90, alignment: .top)
        }

        func collapsed(hover: Bool) -> some View {
            let w = notch.width - 8 + (hover ? 16 : 0), h = notch.height + (hover ? 4 : 0)
            return ZStack(alignment: .top) {
                LinearGradient(colors: [Color(white: 0.82), Color(white: 0.66)], startPoint: .top, endPoint: .bottom)
                NotchShape(ear: 4, bottomRadius: hover ? 12 : 9).fill(Color.black).frame(width: w + 8, height: h)
            }
            .frame(width: 420, height: 90, alignment: .top)
        }

        save(scene(active: nil, busy: false, typing: false, thumbs: [:]), dir.appendingPathComponent("1-open.png"))
        save(scene(active: "wolf", busy: true, typing: false, thumbs: [:]), dir.appendingPathComponent("2-making.png"))
        save(scene(active: "wolf", busy: false, typing: false, thumbs: thumbs), dir.appendingPathComponent("3-wolf-with-your-thumbs.png"))
        save(scene(active: nil, busy: false, typing: true, thumbs: thumbs), dir.appendingPathComponent("4-typing.png"))
        save(scene(active: nil, busy: false, typing: false, thumbs: thumbs,
                   custom: [HairStyle.custom("pink mohawk"), HairStyle.custom("braids")]),
             dir.appendingPathComponent("5-with-custom.png"))
        save(collapsed(hover: false), dir.appendingPathComponent("6-notch.png"))
        save(collapsed(hover: true), dir.appendingPathComponent("7-notch-hover.png"))
    }

    private static func save<V: View>(_ view: V, _ url: URL) {
        let r = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        r.scale = 2
        guard let cg = r.cgImage else { NSLog("render failed: \(url.lastPathComponent)"); return }
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("rendered \(url.path)")
    }
}
