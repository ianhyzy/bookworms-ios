import Foundation
import ImageIO

struct CoverImage: Sendable {
    let image: CGImage
    /// The lowercase SHA-256 of the downloaded bytes, which `SpineDesignV1.coverHash` records.
    let hash: String
    /// The candidate the bytes came from.
    let url: URL
}

enum CoverURLPolicy {
    static func allows(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.user == nil,
            url.password == nil, url.port == nil, url.fragment == nil,
            let host = url.host?.lowercased(), host.contains("."), !host.hasSuffix("."),
            !host.hasSuffix(".local"), !host.hasSuffix(".localhost"),
            !host.hasSuffix(".internal"), host != "localhost", !host.contains(":"),
            !host.split(separator: ".").allSatisfy({ Int($0) != nil })
        else { return false }
        return true
    }
}

private final class HTTPSRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        CoverURLPolicy.allows(request.url) ? request : nil
    }
}

/// Downloads book covers over HTTPS only, with size, pixel, and redirect limits.
actor CoverDownloader {
    private let session: URLSession
    private let maximumBytes = 12 * 1024 * 1024
    private static let maximumPixels = 100_000_000

    /// Creates a downloader. `allowsExpensiveNetwork` is `false` for background runs, so they
    /// wait for Wi-Fi instead of spending cellular data. Tests pass `protocolClasses` to serve
    /// covers without a network.
    init(allowsExpensiveNetwork: Bool = true, protocolClasses: [AnyClass] = []) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = protocolClasses + (configuration.protocolClasses ?? [])
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.allowsExpensiveNetworkAccess = allowsExpensiveNetwork
        configuration.allowsConstrainedNetworkAccess = allowsExpensiveNetwork
        session = URLSession(
            configuration: configuration, delegate: HTTPSRedirectGuard(), delegateQueue: nil)
    }

    /// Downloads the first usable candidate and decodes it at up to 1024 pixels.
    ///
    /// Tries the next candidate only when a cover is missing or unreadable. A network error or a
    /// temporary server error (HTTP 408, 429, or 5xx) propagates as a `URLError`, so a brief
    /// outage does not swap in the other URL and change the cover hash.
    func fetch(_ urls: [URL]) async throws -> CoverImage {
        let (url, data) = try await fetchData(urls)
        guard let image = Self.image(from: data, maximumPixelSize: 1024) else {
            throw CompanionError.invalidCover
        }
        return CoverImage(image: image, hash: CloudContract.digest(data), url: url)
    }

    /// Downloads the first usable candidate's bytes after checking that they decode as an image,
    /// and returns them with the candidate they came from. Falls back as `fetch(_:)` describes.
    ///
    /// - Parameter fallsBackOnServerError: Whether a temporary server error also moves on to the
    ///   next candidate. Display passes `true`, because showing another cover changes no hash;
    ///   generation keeps the default `false`.
    func fetchData(_ urls: [URL], fallsBackOnServerError: Bool = false) async throws -> (
        url: URL, data: Data
    ) {
        var lastError: Error = CompanionError.invalidCover
        for url in urls where CoverURLPolicy.allows(url) {
            do {
                return (url, try await fetchOne(url))
            } catch let error as CompanionError {
                lastError = error
            } catch let error as URLError
                where fallsBackOnServerError && error.code == .badServerResponse
            {
                lastError = error
            }
        }
        throw lastError
    }

    /// Decodes `data` with its EXIF orientation applied, at most `maximumPixelSize` on the long
    /// side. Returns `nil` for unreadable data or an image over 100 megapixels.
    static func image(from data: Data, maximumPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0, width <= maximumPixels / height
        else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(
            source, 0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
    }

    private func fetchOne(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(
            "image/avif,image/webp,image/jpeg,image/png,image/heic", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw CompanionError.invalidCover }
        // A busy or failing server says nothing about the cover, so `fetchData` falls back to
        // another candidate only when its caller opts in; it stops at other `URLError`s.
        if [408, 429].contains(response.statusCode) || (500...599).contains(response.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard response.statusCode == 200, CoverURLPolicy.allows(response.url) else {
            throw CompanionError.invalidCover
        }
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            throw CompanionError.coverTooLarge
        }
        var data = Data()
        data.reserveCapacity(max(0, Int(response.expectedContentLength)))
        for try await byte in bytes {
            data.append(byte)
            if data.count > maximumBytes { throw CompanionError.coverTooLarge }
        }
        // Some CDNs label images as octet streams; decoding decides instead of the MIME type.
        guard !data.isEmpty,
            CGImageSourceCreateWithData(data as CFData, nil)
                .flatMap(CGImageSourceGetType) != nil
        else { throw CompanionError.invalidCover }
        return data
    }
}
