import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

/// Designs a list of books in memory with a chosen model tier and writes what each design read
/// and chose, for review sheets. Debug builds and builds compiled with `SPINE_BATCH`
/// (`script/run_mac.sh --spine-batch`) only.
///
/// `-BookwormsSpineBatch <books.json>` starts a batch at launch, where `books.json` is an array
/// of `CloudBook` records, as an absolute path or one relative to `Caches/Bookworms`.
/// `-BookwormsSpineBatchTier pcc|backup|onDevice|local` picks the tier; the best available
/// tier designs without it (`BookAnalyzer.status(for:)`).
///
/// A batch runs only in a preview launch (`-BookwormsPreviewFolder`), so the app reads no
/// iCloud data, and it never saves: each design stays in memory, and nothing reaches a spine
/// store, the work ledger, or iCloud. It writes `results.json` (each book's design with its
/// `SpineChoice`, or its error), `cover-<id>.png`, and `crop-<id>.png`, the title line the design
/// measured unless several OCR lines share its text, to `Caches/Bookworms/spine-batch/<time>/`,
/// then quits. A request to Private Cloud Compute counts against the reader's daily quota, and
/// one to the backup model is billed to the reader's API account.
enum SpineBatch {
    /// Whether this launch runs a spine batch, which keeps scheduled design runs from starting
    /// (`GenerationController.scheduleChargingTask(hasNewWork:)`). Always `false` in builds
    /// without batches.
    static var isRequested: Bool {
        #if DEBUG || SPINE_BATCH
            UserDefaults.standard.string(forKey: "BookwormsSpineBatch") != nil
        #else
            false
        #endif
    }
}

#if DEBUG || SPINE_BATCH
    extension SpineBatch {
        private static let log = Logger(subsystem: "gay.ian.Bookworms", category: "spine-batch")

        /// One book's outcome in `results.json`.
        struct Result: Codable {
            var id: Int
            var title: String
            var tier: String
            var design: SpineDesignV1?
            var error: String?
            var seconds: Double
        }

        /// Starts the batch that the launch arguments name, if any, and quits when it finishes.
        @MainActor static func startIfRequested() {
            let defaults = UserDefaults.standard
            guard let path = defaults.string(forKey: "BookwormsSpineBatch") else { return }
            guard AppModel.shared.isPreview else {
                log.error("Spine batch refused: it runs only with -BookwormsPreviewFolder")
                return
            }
            let tier = defaults.string(forKey: "BookwormsSpineBatchTier")
            Task {
                do {
                    let folder = try await run(books: resolved(path), tier: tier)
                    log.notice("Spine batch wrote \(folder.path, privacy: .public)")
                } catch {
                    log.error("Spine batch failed: \(String(describing: error), privacy: .public)")
                    exit(1)
                }
                exit(0)
            }
        }

        private static func resolved(_ path: String) -> URL {
            path.hasPrefix("/")
                ? URL(filePath: path) : URL.cachesDirectory.appending(path: "Bookworms/\(path)")
        }

        /// A `-BookwormsSpineBatchTier` value that names no tier.
        struct UnknownTier: Error {
            var name: String
        }

        /// Designs each book in `books` and returns the folder the batch wrote. Stops early when
        /// the tier's quota or provider stops it, or the model is busy or can't be reached.
        /// Throws `UnknownTier`, before any request, for a tier it doesn't know, rather than spend
        /// another tier's quota or billing.
        static func run(books file: URL, tier: String?) async throws -> URL {
            guard tier.map(["pcc", "backup", "onDevice", "local"].contains) ?? true else {
                throw UnknownTier(name: tier ?? "")
            }
            let books = try JSONDecoder().decode([CloudBook].self, from: Data(contentsOf: file))
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "")
            let folder = URL.cachesDirectory.appending(path: "Bookworms/spine-batch/\(stamp)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let analyzer = BookAnalyzer()
            let designer = SpineDesigner.current
            let status: ModelStatus =
                switch tier {
                case "pcc": await analyzer.status(of: .privateCloudCompute, designer: designer)
                case "backup": await analyzer.status(of: .backup, designer: designer)
                case "onDevice": await analyzer.status(of: .onDevice, designer: designer)
                case "local": await analyzer.status(of: .local, designer: designer)
                default: await analyzer.status(for: designer)
                }
            let covers = CoverDownloader()
            let reader = CoverTextReader()
            var results: [Result] = []
            batch: for book in books {
                let start = Date()
                var result = Result(
                    id: book.id, title: book.title, tier: "\(status.tier)", seconds: 0)
                defer {
                    result.seconds = Date().timeIntervalSince(start)
                    results.append(result)
                }
                do {
                    guard status.isAvailable else {
                        throw CompanionError.modelUnavailable
                    }
                    let cover = try await covers.fetch(book.coverCandidates)
                    // Lossless, so a replay of the cover measures the pixels the design did.
                    write(cover.image, as: .png, to: folder.appending(path: "cover-\(book.id).png"))
                    let lines = try await reader.lines(in: cover.image)
                    result.design = try await analyzer.design(
                        book: book, accountID: "spine-batch",
                        workItemHash: CloudContract.digest(Data("\(book.id)".utf8)),
                        cover: cover, using: status)
                    // The line the design measured, which the design model may have chosen,
                    // matched as `SpineChoice` stores its text. A cover that repeats that text
                    // writes no crop, since the matching lines can't say which one was measured.
                    if let text = result.design?.choice?.titleLine {
                        let matches = lines.filter {
                            let read = $0.text.trimmingCharacters(in: .whitespaces)
                            return SpineChoice.storedLine(read) == text
                        }
                        if matches.count == 1,
                            let crop = TitleLettering.measure(cover.image, line: matches[0])?.crop
                        {
                            let file = folder.appending(path: "crop-\(book.id).png")
                            write(crop, as: .png, to: file)
                        }
                    }
                } catch let error as CompanionError {
                    result.error = String(describing: error)
                    if case .quotaReached = error { break batch }
                    if case .providerRejected = error { break batch }
                    if case .keyUnreadable = error { break batch }
                    // A rate limit, outage, or unreachable endpoint would likely answer every
                    // book the same way. A batch sends each book one request, without a
                    // generation run's retries, so it stops at the first.
                    if case .modelBusy = error { break batch }
                    if case .batteryRateLimited = error { break batch }
                    if case .providerUnreachable = error { break batch }
                } catch {
                    result.error = String(describing: error)
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(results).write(to: folder.appending(path: "results.json"))
            return folder
        }

        private static func write(_ image: CGImage, as type: UTType, to url: URL) {
            guard
                let destination = CGImageDestinationCreateWithURL(
                    url as CFURL, type.identifier as CFString, 1, nil)
            else { return }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
    }
#endif
