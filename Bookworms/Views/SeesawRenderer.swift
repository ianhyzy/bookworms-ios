import RealityKit
import SwiftUI

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// Renders Seesaw's share image: the reader's and a friend's books for a time frame weighed on a
/// seesaw on the desk (`SeesawScene`), under a heading, with each reader's name and counts below.
///
/// It renders as the Desk template does (`PileSnapshotRenderer`): one frame of a scene that no
/// view shows, in a `RealityRenderer`, taking its turn with the other renders (`claim()`).
@MainActor
enum SeesawRenderer {
    /// Renders the seesaw for `social`'s two readers, weighing `balance`, under the heading
    /// `period`, at the pixel size of `aspect`. The room behind the desk takes `theme`'s dark
    /// backdrop. Returns the image and the books whose covers missed the wait.
    ///
    /// - Throws: `CancellationError` when the task is cancelled, and `PileSnapshotError` when
    ///   Metal fails or the rendered frame is one flat color.
    static func render(
        _ balance: SeesawBalance, social: ShareSocial, period: String, aspect: ShareAspect,
        theme: ShareTheme, base: SeesawScene.Base, model: AppModel
    ) async throws -> (image: UIImage, late: [CloudBook]) {
        try await PileSnapshotRenderer.claim()
        defer { PileSnapshotRenderer.release() }
        let layout = SeesawLayout(aspect: aspect)
        let size = aspect.size
        let target = try FrameTarget(width: Int(size.width), height: Int(size.height))
        let scene = SeesawScene(textureScale: 2)
        let renderer = try RealityRenderer()
        renderer.entities.append(scene.root)
        defer { renderer.entities.removeAll() }
        renderer.activeCamera = scene.camera
        renderer.cameraSettings.antialiasing = .multisample4X
        renderer.cameraSettings.isToneMappingEnabled = true
        renderer.cameraSettings.colorBackground = .color(theme.backdropDark.uiColor.cgColor)
        let late = await scene.prepare(
            balance, base: base, in: layout.sceneRect, of: size, model: model)
        try Task.checkCancellation()
        try renderer.updateAndRender(
            deltaTime: 1.0 / 60, cameraOutput: target.output,
            actionsAfterRender: [.signal(target.event, value: 1)])
        try await target.read(after: 1, before: .now + .seconds(10))
        let frame = try target.image()
        let card = ImageRenderer(
            content: SeesawCard(
                frame: frame, balance: balance, social: social, period: period, layout: layout,
                theme: theme))
        card.scale = 1
        card.isOpaque = true
        guard let image = card.uiImage else { throw PileSnapshotError.drawingFailed }
        return (image, late)
    }
}

/// Where Seesaw's image puts its heading, its seesaw, and its readers.
struct SeesawLayout: Equatable {
    let aspect: ShareAspect

    var titleSize: CGFloat { aspect == .story ? 120 : 96 }
    var avatarSize: CGFloat { aspect == .story ? 120 : 96 }

    /// The part of the image the seesaw is framed in: below the heading, above the readers.
    var sceneRect: CGRect {
        let size = aspect.size
        let insets = aspect.insets
        let top = insets.top + titleSize * 1.25 + 90
        let bottom = size.height - insets.bottom - avatarSize - 150
        return CGRect(x: insets.leading / 2, y: top, width: size.width - insets.leading, height: bottom - top)
    }
}

/// The share image: the rendered seesaw, the heading over it, and the two readers below it, the
/// reader on the left under their books and the friend on the right.
struct SeesawCard: View {
    let frame: CGImage
    let balance: SeesawBalance
    let social: ShareSocial
    let period: String
    let layout: SeesawLayout
    let theme: ShareTheme

    var body: some View {
        let size = layout.aspect.size
        let insets = layout.aspect.insets
        Image(decorative: frame, scale: 1).resizable()
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [theme.backdropDark.color, theme.backdropDark.color.opacity(0)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: layout.sceneRect.minY + 60)
            }
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [theme.backdropDark.color.opacity(0), theme.backdropDark.color],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: size.height - layout.sceneRect.maxY + 120)
            }
            .overlay(alignment: .top) {
                VStack(spacing: 10) {
                    Text(period)
                        .font(ShareStyle.serif(layout.titleSize, .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(verdict)
                        .font(ShareStyle.serif(44))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .opacity(0.85)
                }
                .padding(.top, insets.top)
                .padding(.horizontal, insets.leading)
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 36) {
                    HStack(alignment: .top) {
                        reader(social.owner, side: balance.mine, alignment: .leading)
                        Spacer(minLength: 24)
                        reader(social.reader, side: balance.theirs, alignment: .trailing)
                    }
                    ShareInviteLine(username: social.owner.username)
                }
                .padding(.horizontal, insets.leading)
                .padding(.bottom, insets.bottom)
            }
            .foregroundStyle(ShareStyle.cream.color)
            .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
            .environment(\.colorScheme, .dark)
    }

    /// Who read more, and by how many pages.
    private var verdict: String {
        let difference = abs(balance.mine.pages - balance.theirs.pages).formatted()
        return switch balance.lean {
        case .mine: "\(social.owner.shortName) read \(difference) more pages"
        case .theirs: "\(social.reader.shortName) read \(difference) more pages"
        case .level: "Perfectly balanced"
        }
    }

    private func reader(
        _ profile: ReaderProfile, side: SeesawBalance.Side, alignment: HorizontalAlignment
    ) -> some View {
        let books = side.books.count == 1 ? "1 book" : "\(side.books.count.formatted()) books"
        return VStack(alignment: alignment, spacing: 12) {
            ShareAvatar(
                profile: profile, image: social.avatars[profile.id], size: layout.avatarSize,
                fill: theme.panel(alignment == .leading ? 0 : 1))
            Text(profile.shortName)
                .font(ShareStyle.serif(46, .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("\(books) · \(side.pages.formatted()) pages")
                .font(ShareStyle.serif(34))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .opacity(0.85)
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .top))
    }
}
