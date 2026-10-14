#if os(macOS)
    import AppKit
    import SwiftUI

    // The Mac build compiles the iPhone's source. These aliases name AppKit's image, color, and
    // font types after their UIKit counterparts, and the extensions add the UIKit members the
    // shared code uses, so drawing code stays one implementation.

    typealias UIImage = NSImage
    typealias UIColor = NSColor
    typealias UIFont = NSFont
    typealias UIFontDescriptor = NSFontDescriptor

    extension NSImage {
        convenience init(cgImage: CGImage) {
            self.init(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))
        }

        /// The image's bitmap at its pixel size.
        var cgImage: CGImage? {
            var rect = CGRect(origin: .zero, size: size)
            return cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }

        enum RenderingMode { case alwaysOriginal }

        /// The SF Symbol `systemName` drawn with `configuration`.
        convenience init?(systemName: String, withConfiguration configuration: SymbolConfiguration)
        {
            guard
                let symbol = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
                    .withSymbolConfiguration(configuration)
            else { return nil }
            self.init(size: symbol.size, flipped: false) { rect in
                symbol.draw(in: rect)
                return true
            }
        }

        /// A copy of this image's shape filled with `color`, as UIKit tints a symbol.
        func withTintColor(_ color: NSColor, renderingMode: RenderingMode) -> NSImage {
            NSImage(size: size, flipped: false) { rect in
                self.draw(in: rect)
                color.set()
                rect.fill(using: .sourceAtop)
                return true
            }
        }

        /// Bridge images are sized in pixels, so one point is one pixel.
        var scale: CGFloat { 1 }

        func pngData() -> Data? {
            cgImage.flatMap {
                NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:])
            }
        }

        func jpegData(compressionQuality: CGFloat) -> Data? {
            cgImage.flatMap {
                NSBitmapImageRep(cgImage: $0)
                    .representation(
                        using: .jpeg, properties: [.compressionFactor: compressionQuality])
            }
        }
    }

    extension NSFont {
        var lineHeight: CGFloat { ceil(ascender - descender + leading) }
    }

    extension ImageRenderer {
        /// The rendered bitmap as a pixel-sized image.
        @MainActor var uiImage: NSImage? { cgImage.map { NSImage(cgImage: $0) } }
    }

    extension Image {
        init(uiImage: NSImage) { self.init(nsImage: uiImage) }
    }

    extension Color {
        init(uiColor: NSColor) { self.init(nsColor: uiColor) }
    }

    /// The iPhone's title display modes, which a Mac window title ignores.
    enum TitleDisplayMode { case automatic, inline, large }

    extension View {
        func navigationBarTitleDisplayMode(_ mode: TitleDisplayMode) -> Self { self }
    }

    extension ToolbarItemPlacement {
        static var topBarTrailing: Self { primaryAction }
        static var topBarLeading: Self { navigation }
    }

    /// The UIKit notification that shared views observe for memory pressure.
    enum UIApplication {
        static let didReceiveMemoryWarningNotification = Notification.Name(
            "BookwormsMemoryWarning")

        /// Posts `didReceiveMemoryWarningNotification` on the main queue whenever macOS reports
        /// memory pressure, as iOS does for a memory warning. Call once at launch.
        @MainActor static func reportMemoryPressure() {
            let source = DispatchSource.makeMemoryPressureSource(
                eventMask: [.warning, .critical], queue: .main)
            source.setEventHandler {
                NotificationCenter.default.post(
                    name: didReceiveMemoryWarningNotification, object: nil)
            }
            source.activate()
            memoryPressureSource = source
        }

        @MainActor private static var memoryPressureSource: (any DispatchSourceMemoryPressure)?
    }

    /// The general pasteboard's text, as UIKit's pasteboard offers it.
    struct UIPasteboard {
        static var general: UIPasteboard { UIPasteboard() }

        var string: String? {
            get { NSPasteboard.general.string(forType: .string) }
            nonmutating set {
                NSPasteboard.general.clearContents()
                if let newValue { NSPasteboard.general.setString(newValue, forType: .string) }
            }
        }
    }

    /// Options for `UIGraphicsImageRenderer`, as UIKit's format offers them.
    final class UIGraphicsImageRendererFormat {
        var scale: CGFloat = 1
        var opaque = false
        static func preferred() -> UIGraphicsImageRendererFormat { .init() }
    }

    /// The drawing context passed to a `UIGraphicsImageRenderer` action.
    struct UIGraphicsImageRendererContext {
        let cgContext: CGContext

        func fill(_ rect: CGRect) { cgContext.fill(rect) }
    }

    /// Draws into a bitmap with UIKit's top-left origin, so AppKit and string drawing match
    /// the iPhone's output.
    struct UIGraphicsImageRenderer {
        let bounds: CGRect
        let format: UIGraphicsImageRendererFormat

        init(size: CGSize, format: UIGraphicsImageRendererFormat = .init()) {
            self.init(bounds: CGRect(origin: .zero, size: size), format: format)
        }

        init(bounds: CGRect, format: UIGraphicsImageRendererFormat = .init()) {
            self.bounds = bounds
            self.format = format
        }

        func image(actions: (UIGraphicsImageRendererContext) -> Void) -> NSImage {
            guard let cgImage = draw(actions) else { return NSImage(size: bounds.size) }
            return NSImage(cgImage: cgImage, size: bounds.size)
        }

        func pngData(actions: (UIGraphicsImageRendererContext) -> Void) -> Data {
            image(actions: actions).pngData() ?? Data()
        }

        func jpegData(
            withCompressionQuality quality: CGFloat,
            actions: (UIGraphicsImageRendererContext) -> Void
        ) -> Data {
            image(actions: actions).jpegData(compressionQuality: quality) ?? Data()
        }

        private func draw(_ actions: (UIGraphicsImageRendererContext) -> Void) -> CGImage? {
            let width = Int((bounds.width * format.scale).rounded(.up))
            let height = Int((bounds.height * format.scale).rounded(.up))
            guard width > 0, height > 0,
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: format.opaque
                        ? CGImageAlphaInfo.noneSkipLast.rawValue
                        : CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            // Flips to UIKit's coordinates: origin at the top left, y growing downward.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: format.scale, y: -format.scale)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            actions(UIGraphicsImageRendererContext(cgContext: context))
            NSGraphicsContext.restoreGraphicsState()
            return context.makeImage()
        }
    }
#endif
