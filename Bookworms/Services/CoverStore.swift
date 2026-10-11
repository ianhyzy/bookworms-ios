import Foundation
import UIKit

/// Serves cover images for display, from memory, then disk, then the network.
///
/// Downloads go through `CoverDownloader`'s HTTPS and size limits. When the first cover
/// candidate that `CoverURLPolicy` allows is missing, unreadable, or its server reports a
/// temporary error, a later candidate shows instead. The raw bytes of that first allowed
/// candidate are kept in Caches so later launches decode locally; the system may evict them,
/// which only costs a download. A fallback candidate's image is kept only in memory, so the next
/// launch tries the first candidate again. Decoded images are bounded in memory by `NSCache`.
actor CoverStore {
    private let downloader = CoverDownloader()
    private let folder = URL.cachesDirectory.appending(path: "Bookworms/covers")
    private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<Data?, Never>] = [:]

    init() {
        memory.totalCostLimit = 96 * 1024 * 1024
    }

    /// Returns the book's cover at most `maximumPixelSize` on its long side, or `nil` when the
    /// book has no usable cover.
    func image(for book: CloudBook, maximumPixelSize: Int = 768) async -> UIImage? {
        guard let first = book.coverCandidates.first else { return nil }
        let key = CloudContract.digest(first.absoluteString)
        let cacheKey = "\(key)@\(maximumPixelSize)" as NSString
        if let cached = memory.object(forKey: cacheKey) { return cached }
        guard let data = await data(for: book, key: key),
            let cgImage = CoverDownloader.image(from: data, maximumPixelSize: maximumPixelSize)
        else { return nil }
        let image = UIImage(cgImage: cgImage)
        memory.setObject(image, forKey: cacheKey, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }

    /// Shares one download between callers that ask for the same cover at once.
    private func data(for book: CloudBook, key: String) async -> Data? {
        let file = folder.appending(path: key)
        if let data = try? Data(contentsOf: file) { return data }
        if let task = inFlight[key] { return await task.value }
        let task = Task { [downloader, folder] () -> Data? in
            guard
                let cover = try? await downloader.fetchData(
                    book.coverCandidates, fallsBackOnServerError: true)
            else {
                return nil
            }
            // The file holds the first candidate the policy allows; a fallback's bytes stay out.
            if cover.url == book.coverCandidates.first(where: { CoverURLPolicy.allows($0) }) {
                try? FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true)
                try? cover.data.write(to: file, options: .atomic)
            }
            return cover.data
        }
        inFlight[key] = task
        let data = await task.value
        inFlight[key] = nil
        return data
    }
}
