import AppKit

/// A haircut you can try. `look` is the plain description that gets slotted into the
/// prompts for the live models (Eden Live and Decart Lucy).
struct HairStyle: Identifiable, Hashable, Codable {
    let id: String
    let look: String
    var isCustom: Bool = false

    var livePrompt: String {
        "Change the person's hair to \(look). Keep the same face, identity, expression, clothing and background."
    }

    /// For Nano Banana, making the "you with the cut" frame that anchors Eden Live.
    var anchorPrompt: String {
        "Edit only the hair: give this person \(look). Keep exactly the same face, identity, expression, skin, "
            + "lighting, clothing, background, camera angle and framing. Photorealistic photo."
    }

    /// Eden Live wants a description of what the video should look like.
    var edenPrompt: String {
        "A photorealistic live video of the same person with \(look). Same face, identity, expression, skin, "
            + "clothing, lighting and background as the camera."
    }

    /// The little picture in the circle before you've tried it on yourself.
    var icon: NSImage? {
        guard !isCustom,
              let url = Bundle.main.url(forResource: id, withExtension: "png", subdirectory: "styles")
        else { return nil }
        return NSImage(contentsOf: url)
    }

    static let builtIn: [HairStyle] = [
        HairStyle(id: "buzz", look: "a very short buzz cut, clipped evenly close to the scalp"),
        HairStyle(id: "crop", look: "a textured French crop haircut: short messy textured top with a short blunt fringe and faded sides"),
        HairStyle(id: "curtains", look: "curtain hair: medium-length hair parted in the middle, falling in soft curtains to the cheekbones"),
        HairStyle(id: "mullet", look: "a mullet haircut: short on top and at the sides, with clearly longer hair at the back flowing down past the neck onto the shoulders"),
        HairStyle(id: "wolf", look: "a shaggy wolf cut: choppy layered shag with volume on top, wispy curtain bangs and longer layers at the neck"),
        HairStyle(id: "long", look: "long, flowing, layered hair falling well past the shoulders"),
        HairStyle(id: "blonde", look: "bleached platinum blonde hair, keeping the current haircut, length and shape"),
        HairStyle(id: "black", look: "glossy jet black hair, keeping the current haircut, length and shape"),
    ]

    static func custom(_ text: String) -> HairStyle {
        HairStyle(id: "custom-" + UUID().uuidString.prefix(8).lowercased(), look: text, isCustom: true)
    }
}

/// Where Mane keeps its few files: ~/Library/Application Support/Mane
enum AppFiles {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("Mane", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static let thumbs: URL = {
        let d = dir.appendingPathComponent("thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
}

/// The fal.ai key. Stored in a private file (0600) in Application Support rather than the
/// Keychain, so a rebuilt app doesn't ask for your password every update.
enum KeyStore {
    private static var file: URL { AppFiles.dir.appendingPathComponent("fal.key") }

    static var key: String? {
        if let env = ProcessInfo.processInfo.environment["FAL_KEY"], !env.isEmpty { return env }
        guard let s = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let k = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return k.isEmpty ? nil : k
    }

    static func save(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty {
            try? FileManager.default.removeItem(at: file)
            return
        }
        FileManager.default.createFile(atPath: file.path, contents: Data(k.utf8),
                                       attributes: [.posixPermissions: 0o600])
    }
}

/// Your own face with each cut, saved after you try it, shown in the circles.
enum ThumbStore {
    static func url(_ id: String) -> URL { AppFiles.thumbs.appendingPathComponent(id + ".jpg") }

    static func loadAll(ids: [String]) -> [String: NSImage] {
        var out: [String: NSImage] = [:]
        for id in ids { if let img = NSImage(contentsOf: url(id)) { out[id] = img } }
        return out
    }

    static func save(_ id: String, jpeg: Data, mirrored: Bool = false) -> NSImage? {
        guard let src = NSImage(data: jpeg) else { return nil }
        let side: CGFloat = 144
        let thumb = NSImage(size: NSSize(width: side, height: side))
        thumb.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        // Zoom in on where a face sits in the mirror (upper middle), so the circle shows
        // your head and hair rather than the whole room.
        let s = src.size, m = min(s.width, s.height) * 0.62
        let cx = s.width / 2, cy = s.height * 0.63
        if mirrored {   // camera frames aren't mirrored; the circles show you as the mirror does
            let t = NSAffineTransform()
            t.translateX(by: side, yBy: 0)
            t.scaleX(by: -1, yBy: 1)
            t.concat()
        }
        src.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                 from: NSRect(x: cx - m / 2, y: min(max(cy - m / 2, 0), s.height - m), width: m, height: m),
                 operation: .copy, fraction: 1)
        thumb.unlockFocus()
        if let tiff = thumb.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
            try? data.write(to: url(id))
        }
        return thumb
    }

    static func remove(_ id: String) { try? FileManager.default.removeItem(at: url(id)) }
}

/// Haircuts you typed with the + button (the last few are kept).
enum CustomStore {
    private static let key = "customStyles"
    static let limit = 3

    static func load() -> [HairStyle] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([HairStyle].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [HairStyle]) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
    }
}
