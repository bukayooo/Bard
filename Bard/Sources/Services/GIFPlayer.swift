import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Decodes every frame of a GIF up front (Bard's GIFs are all short loops — a
/// dozen-odd frames — so this is cheap) and exposes both the frame sequence and
/// the first frame's average color, used to tint the Synthesis screen so its
/// background reads as part of the same image rather than a mismatched backdrop.
@MainActor
final class GIFPlayer {
    let totalDuration: Double
    let averageColor: Color
    /// The GIF's native pixel dimensions, so a view can size itself to exactly
    /// match this aspect ratio instead of relying on SwiftUI's aspectRatio(.fit)
    /// inside an oversized box — which reports the box's full size to layout and
    /// leaves a letterboxed gap for any clip/border applied around it.
    let pixelSize: CGSize

    private let frames: [CGImage]
    private let frameDurations: [Double]

    private init(frames: [CGImage], frameDurations: [Double], averageColor: Color, pixelSize: CGSize) {
        self.frames = frames
        self.frameDurations = frameDurations
        self.totalDuration = frameDurations.reduce(0, +)
        self.averageColor = averageColor
        self.pixelSize = pixelSize
    }

    /// Which frame should be on screen `time` seconds into the loop.
    func frame(at time: Double) -> CGImage {
        guard totalDuration > 0 else { return frames[0] }
        var t = time.truncatingRemainder(dividingBy: totalDuration)
        for (i, duration) in frameDurations.enumerated() {
            if t < duration { return frames[i] }
            t -= duration
        }
        return frames[frames.count - 1]
    }

    static func load(url: URL) -> GIFPlayer? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        var frames: [CGImage] = []
        var durations: [Double] = []
        frames.reserveCapacity(count)
        durations.reserveCapacity(count)
        for i in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            frames.append(cgImage)
            durations.append(frameDuration(source: source, index: i))
        }
        guard let firstFrame = frames.first else { return nil }
        let pixelSize = CGSize(width: firstFrame.width, height: firstFrame.height)
        return GIFPlayer(
            frames: frames, frameDurations: durations, averageColor: averageColor(of: firstFrame),
            pixelSize: pixelSize)
    }

    /// GIF timing lives per-frame in its own GIF-specific properties dictionary,
    /// not on the image itself. Delays under ~20ms are a GIF-encoder convention
    /// for "as fast as possible" rather than a literal duration — browsers and
    /// other decoders clamp these to a visible default instead of spinning near
    /// 0s, which is mirrored here.
    private static func frameDuration(source: CGImageSource, index: Int) -> Double {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
            let gifProperties = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return 0.1 }
        let duration =
            (gifProperties[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gifProperties[kCGImagePropertyGIFDelayTime] as? Double)
            ?? 0.1
        return duration < 0.02 ? 0.1 : duration
    }

    /// Downsamples the frame to a single pixel — cheap way to get its average
    /// color without walking every pixel by hand.
    private static func averageColor(of image: CGImage) -> Color {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return BardTheme.charcoal }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = context.data else { return BardTheme.charcoal }
        let pixel = data.bindMemory(to: UInt8.self, capacity: 4)
        return Color(red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255)
    }
}

extension Color {
    /// WCAG relative luminance — used to decide whether a *computed* background
    /// color (e.g. a GIF's average color) reads as visually dark or light, since
    /// that can't be assumed from the app's own light/dark color scheme.
    var relativeLuminance: Double {
        let color = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor.black
        func linearize(_ c: CGFloat) -> Double {
            let c = Double(c)
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(color.redComponent) + 0.7152 * linearize(color.greenComponent)
            + 0.0722 * linearize(color.blueComponent)
    }

    var isPerceptuallyDark: Bool { relativeLuminance < 0.45 }
}

/// A looping animated GIF, rendered frame-by-frame from a pre-decoded `GIFPlayer`.
///
/// Sized to `maxSize` via an *exact* width/height computed from the GIF's own
/// pixel dimensions, rather than a `.frame(maxWidth:maxHeight:)` + `.aspectRatio(.fit)`
/// pair: a resizable Image inside a max-only frame reports the frame's full box
/// as its layout size and only letterboxes the drawn pixels within it, so any
/// clip shape or border applied around it (see SynthesisProgressView) would hug
/// the oversized box instead of the visible image.
struct AnimatedGIFView: View {
    let player: GIFPlayer
    let maxSize: CGSize
    @State private var startDate = Date()

    private var renderSize: CGSize {
        let pixelSize = player.pixelSize
        guard pixelSize.width > 0, pixelSize.height > 0 else { return maxSize }
        let scale = min(maxSize.width / pixelSize.width, maxSize.height / pixelSize.height)
        return CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
    }

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(startDate)
            Image(decorative: player.frame(at: elapsed), scale: 1)
                .resizable()
                .interpolation(.high)
        }
        .frame(width: renderSize.width, height: renderSize.height)
    }
}

/// Bard's four bundled synthesis-screen GIFs, rotated so consecutive audiobook
/// jobs don't show the same one twice in a row. Selection and decoding are kept
/// separate: `nextFilename()` just advances a persisted index (so it can be
/// called cheaply from a job's init), while `player(for:)` does the actual decode
/// and caches the result, since the same GIF will come up again once the
/// rotation wraps around.
@MainActor
enum SynthesisGIFLibrary {
    static let filenames = [
        "zoopraxography-fan-flirtation",
        "zoopraxography-grecian-dancing-girls",
        "pottery-scholar",
        "pottery-runners",
    ]

    private static let defaultsKey = "lastSynthesisGIFIndex"
    private static var cache: [String: GIFPlayer] = [:]

    static func nextFilename() -> String {
        let defaults = UserDefaults.standard
        let next = (defaults.integer(forKey: defaultsKey) + 1) % filenames.count
        defaults.set(next, forKey: defaultsKey)
        return filenames[next]
    }

    static func player(for filename: String) -> GIFPlayer? {
        if let cached = cache[filename] { return cached }
        // The Resources/GIFs/ folder on disk is a plain Xcode group, not a folder
        // reference, so XcodeGen/Xcode copy its contents flat into the app's
        // top-level Resources dir rather than preserving the GIFs/ subdirectory.
        guard let url = Bundle.main.url(forResource: filename, withExtension: "gif") else { return nil }
        let player = GIFPlayer.load(url: url)
        cache[filename] = player
        return player
    }
}
