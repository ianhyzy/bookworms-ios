import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers
import XCTest

@testable import Bookworms

/// Covers how `CoverStore` forgets its images, as a sign-out asks: from memory and disk, and
/// without keeping an image that was still downloading. No test uses the network.
final class CoverStoreTests: XCTestCase {
    private func folder() -> URL {
        let folder = URL.temporaryDirectory.appending(path: "cover-store-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private static func png() throws -> Data {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.4, green: 0.2, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// `clear()` forgets a cached image in memory and on disk. The image's address is one the
    /// cover policy refuses, so only the cache can serve it and nothing downloads.
    func testClearForgetsCachedImages() async throws {
        let folder = folder()
        let photo = try XCTUnwrap(URL(string: "http://photos.example.com/fictional-reader.png"))
        XCTAssertFalse(CoverURLPolicy.allows(photo))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.png().write(to: folder.appending(path: CloudContract.digest(photo.absoluteString)))
        let store = CoverStore(folder: folder)

        let cached = await store.image(at: [photo])
        XCTAssertNotNil(cached, "The disk cache serves the image")
        try FileManager.default.removeItem(at: folder)
        let remembered = await store.image(at: [photo])
        XCTAssertNotNil(remembered, "Memory serves it without the file")

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.png().write(to: folder.appending(path: CloudContract.digest(photo.absoluteString)))
        await store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path()))
        let forgotten = await store.image(at: [photo])
        XCTAssertNil(forgotten, "Neither memory nor disk holds the image")
    }

    /// An image that is downloading when `clear()` runs reaches its caller but isn't kept: no
    /// file, and the next request downloads again.
    func testADownloadThatClearOvertakesIsNotKept() async throws {
        HeldCover.reset(serving: try Self.png())
        let folder = folder()
        let store = CoverStore(
            folder: folder, downloader: CoverDownloader(protocolClasses: [HeldCover.self]))
        let photo = try XCTUnwrap(URL(string: "https://photos.example.com/fictional-reader.png"))

        async let loading = store.image(at: [photo])
        await HeldCover.waitForRequest()
        await store.clear()
        HeldCover.release()
        let loaded = await loading
        XCTAssertNotNil(loaded, "The caller that asked still gets the image")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path()), "Nothing is saved")

        async let again = store.image(at: [photo])
        await HeldCover.waitForRequest()
        HeldCover.release()
        let reloaded = await again
        XCTAssertNotNil(reloaded)
        XCTAssertEqual(HeldCover.requests, 2, "Memory didn't keep the first image")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: folder.appending(path: CloudContract.digest(photo.absoluteString)).path()),
            "A download after the clear saves as usual")
    }
}

/// Answers every request with one image, but only once the test releases it, so a test can act
/// while the download is in flight.
private final class HeldCover: URLProtocol, @unchecked Sendable {
    private struct State {
        var image = Data()
        var requests = 0
        var held: [HeldCover] = []
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private static let state = Mutex(State())

    static var requests: Int { state.withLock { $0.requests } }

    static func reset(serving image: Data) {
        state.withLock { $0 = State(image: image) }
    }

    /// Returns once a request is held.
    static func waitForRequest() async {
        await withCheckedContinuation { continuation in
            let isHeld = state.withLock { state in
                if state.held.isEmpty { state.waiters.append(continuation) }
                return !state.held.isEmpty
            }
            if isHeld { continuation.resume() }
        }
    }

    /// Answers the held requests.
    static func release() {
        let (held, image) = state.withLock { state in
            defer { state.held = [] }
            return (state.held, state.image)
        }
        for request in held {
            guard let url = request.request.url,
                let response = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "image/png"])
            else { continue }
            request.client?
                .urlProtocol(request, didReceive: response, cacheStoragePolicy: .notAllowed)
            request.client?.urlProtocol(request, didLoad: image)
            request.client?.urlProtocolDidFinishLoading(request)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let waiters = Self.state.withLock { state in
            defer { state.waiters = [] }
            state.requests += 1
            state.held.append(self)
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
    override func stopLoading() {}
}
