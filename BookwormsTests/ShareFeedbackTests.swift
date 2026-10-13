import CoreGraphics
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
        let creditTop = exported.height - 48
        var changedAbove = 0
        var changedInCredit = 0
        for index in stride(from: 0, to: original.bytes.count, by: 4) {
            let difference = (0..<3)
                .map {
                    abs(Int(original.bytes[index + $0]) - Int(exported.bytes[index + $0]))
                }
                .max()!
            let row = index / 4 / exported.width
            if row < creditTop, difference > 2 { changedAbove += 1 }
            if row >= creditTop, difference > 30 { changedInCredit += 1 }
        }
        XCTAssertEqual(changedAbove, 0)
        XCTAssertGreaterThan(changedInCredit, 1000)
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
