import CoreGraphics
import CoreTransferable
import UIKit
import XCTest

@testable import Bookworms

final class ShareFeedbackTests: XCTestCase {
    func testShareOutcomeNamesWhatTheReaderDid() {
        let failure = NSError(domain: "fixture", code: 1)
        let cases: [(UIActivity.ActivityType?, Bool, (any Error)?, ShareOutcome)] = [
            (.saveToCameraRoll, true, nil, .savedToPhotos),
            (.copyToPasteboard, true, nil, .copied),
            (.message, true, nil, .shared),
            (UIActivity.ActivityType("com.burbn.instagram.shareextension"), true, nil, .shared),
            (nil, false, nil, .cancelled),
            (.message, false, nil, .cancelled),
            (.saveToCameraRoll, false, CocoaError(.userCancelled), .cancelled),
            (.saveToCameraRoll, false, failure, .failed("Couldn't save to Photos")),
            (.airDrop, false, failure, .failed("Couldn't share")),
        ]
        for (activity, completed, error, expected) in cases {
            XCTAssertEqual(
                ShareOutcome(activity: activity, completed: completed, error: error), expected,
                "\(String(describing: activity)) \(completed)")
        }
        XCTAssertEqual(ShareOutcome.savedToPhotos.toast?.message, "Saved to Photos")
        XCTAssertEqual(ShareOutcome.shared.toast?.message, "Shared")
        XCTAssertNil(ShareOutcome.cancelled.toast)
        XCTAssertEqual(ShareOutcome.failed("Couldn't share").toast?.isError, true)
    }

    /// The preview image has no credit; the shared PNG is the same image with the credit in its
    /// bottom few pixels.
    @MainActor
    func testSharedImageAddsTheCreditAtTheBottomEdgeOnly() async throws {
        let book = CloudBook(
            id: 1, title: "Fictional Book", author: "An Author", coverURL: nil,
            detailCoverURL: nil, finished: "2025-03-15", rating: 4)
        let input = ShareInput(
            template: .justFinished, aspect: .story, books: [book], frame: .year(2025))
        let preview = try XCTUnwrap(input.render())
        let files = try await SharedFiles.images([ShareImage(image: preview, name: "A/B")])
        let url = try XCTUnwrap(files.urls.first)
        XCTAssertEqual(files.urls.count, 1)
        XCTAssertEqual(url.lastPathComponent, "A-B.png")
        let shared = try XCTUnwrap(UIImage(contentsOfFile: url.path())?.cgImage)
        let original = try Self.pixels(XCTUnwrap(preview.cgImage))
        let exported = try Self.pixels(shared)
        XCTAssertEqual(exported.width, 1080)
        XCTAssertEqual(exported.height, 1920)
        // The credit's text ends about 10 pixels above the edge and stands about 30 tall.
        let changes = Self.changedRows(original, exported, in: (1920 - 48)..<1920)
        XCTAssertEqual(changes.outside, 0)
        XCTAssertGreaterThan(changes.inside, 1000)
    }

    /// A dragged, copied, or saved image is the same credited PNG that sharing writes, and the
    /// Quick Look file in its own folder survives the next share, which replaces its own files.
    @MainActor
    func testTransferredImageCarriesTheCreditAndPreviewFilesStay() async throws {
        let book = CloudBook(
            id: 1, title: "Fictional Book", author: "An Author", coverURL: nil,
            detailCoverURL: nil, finished: "2025-03-15", rating: 4)
        let input = ShareInput(
            template: .justFinished, aspect: .square, books: [book], frame: .year(2025))
        let image = ShareImage(image: try XCTUnwrap(input.render()), name: "Fictional")
        let transferred = try await image.exported(as: .png)
        let shared = try await SharedFiles.images([image])
        XCTAssertEqual(transferred, try Data(contentsOf: try XCTUnwrap(shared.urls.first)))
        XCTAssertEqual(image, ShareImage(image: image.image, name: "Fictional"))

        let preview = try await SharedFiles.images([image], in: "Preview")
        _ = try await SharedFiles.images([image])
        let url = try XCTUnwrap(preview.urls.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path()))
    }

    /// A **My reading** image letters the profile link in its bottom margin and nowhere else: on
    /// a Story above the bottom 150 pixels, which the platforms' reply bar may cover, and on
    /// Portrait above the credit's strip. The longest username fits the width.
    @MainActor
    func testProfileLinkSitsInTheBottomMarginAboveTheReplyBar() throws {
        let book = CloudBook(
            id: 1, title: "Fictional Book", author: "An Author", coverURL: nil,
            detailCoverURL: nil, finished: "2025-03-15", rating: 4, review: "A fictional review.")
        let bands: [(ShareAspect, Range<Int>)] = [(.story, 1690..<1770), (.portrait, 1262..<1310)]
        for (aspect, band) in bands {
            // Review stays within `ShareAspect.insets`, so the link alone changes the image.
            var input = ShareInput(
                template: .review, aspect: aspect, books: [book], frame: .year(2025))
            let plain = try Self.pixels(XCTUnwrap(input.render()?.cgImage))
            input.username = "fictional_reader"
            let linked = try Self.pixels(XCTUnwrap(input.render()?.cgImage))
            let changes = Self.changedRows(plain, linked, in: band)
            XCTAssertEqual(changes.outside, 0, aspect.title)
            XCTAssertGreaterThan(changes.inside, 1000, aspect.title)
        }

        // Cards that reach into a story's bottom strip leave the link its room.
        var input = ShareInput(template: .topFive, aspect: .story, books: [book])
        XCTAssertEqual(input.reachingInsets.bottom, 150)
        input.username = "fictional_reader"
        XCTAssertEqual(input.reachingInsets.bottom, 150 + ShareProfileLink.storyHeight)

        let longest = HardcoverInvite.link(String(repeating: "W", count: 40))
        let font = UIFont.systemFont(ofSize: ShareProfileLink.fontSize, weight: .semibold)
        let width = (longest as NSString).size(withAttributes: [.font: font]).width
        XCTAssertLessThanOrEqual(width * ShareProfileLink.minimumScale, 1080 - 2 * 64)
    }

    /// How many pixels differ between `before` and `after`: by more than 30 inside the rows
    /// `rows`, where text draws, and by more than 2 outside them.
    private static func changedRows(
        _ before: (bytes: [UInt8], width: Int, height: Int),
        _ after: (bytes: [UInt8], width: Int, height: Int), in rows: Range<Int>
    ) -> (inside: Int, outside: Int) {
        var inside = 0
        var outside = 0
        for index in stride(from: 0, to: before.bytes.count, by: 4) {
            let difference = (0..<3)
                .map { abs(Int(before.bytes[index + $0]) - Int(after.bytes[index + $0])) }
                .max()!
            if rows.contains(index / 4 / before.width) {
                if difference > 30 { inside += 1 }
            } else if difference > 2 {
                outside += 1
            }
        }
        return (inside, outside)
    }

    /// `image` drawn into an sRGB RGBA context, so that two images compare byte for byte.
    private static func pixels(_ image: CGImage) throws -> (
        bytes: [UInt8], width: Int, height: Int
    ) {
        let (width, height) = (image.width, image.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(
                CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (bytes, width, height)
    }
}
