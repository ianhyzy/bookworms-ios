import Foundation
import Observation
import Security

/// This iPhone's own Hardcover sign-in: the device-code flow, the saved login, and the library
/// it syncs.
///
/// The access token stays in this device's Keychain. The library goes to the `PhoneLibrary`
/// cache, which `CloudSpineStore` reads to show and design the account's books. The saved
/// `Summary` marks the sign-in for the store (`signedInAccountID`). After a sign-in, sync, or
/// sign-out changes that cache, `libraryRevision` increases and `onLibraryChange` runs.
@MainActor
@Observable
final class HardcoverAccount {
    /// A sign-in in progress.
    enum SignIn: Equatable {
        case requestingCode
        /// Waiting for the reader to approve `code` at `url`.
        case waiting(code: String, url: URL)
        case connecting
        case failed(String)
    }

    /// The signed-in account, kept in user defaults so the sheet and the staleness check need no
    /// library read.
    struct Summary: Codable, Equatable {
        let accountID: String
        let username: String?
        /// When the library was last downloaded; `nil` before the first sync.
        var syncedAt: Date?
    }

    /// Syncs at launch or activation wait this long after the last one.
    static let staleInterval: TimeInterval = 4 * 60 * 60

    private(set) var isSignedIn: Bool
    private(set) var summary: Summary?
    private(set) var signIn: SignIn?
    private(set) var isSyncing = false
    private(set) var syncError: String?
    /// Whether Hardcover rejected the saved login, so only a new sign-in can sync again. The
    /// cached library stays until then.
    private(set) var needsReconnect = false
    /// Increases whenever the cached library changes, so a load that read the old cache can
    /// tell.
    private(set) var libraryRevision = 0
    @ObservationIgnored var onLibraryChange: (() -> Void)?

    @ObservationIgnored private let tokens: HardcoverTokenStore
    @ObservationIgnored private let client: HardcoverClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let libraryURL: URL
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<PhoneLibrary, any Error>?
    nonisolated static let summaryKey = "HardcoverAccount"

    /// The signed-in account's ID, or `nil` when signed out. Readable from any isolation.
    ///
    /// `CloudSpineStore` chooses the library source from this rather than from the library
    /// cache, which iOS may evict, so a signed-in iPhone never falls back to the Apple TV
    /// archive, which may belong to another account.
    nonisolated static var signedInAccountID: String? {
        UserDefaults.standard.data(forKey: summaryKey)
            .flatMap { try? JSONDecoder().decode(Summary.self, from: $0) }?
            .accountID
    }

    /// Tests pass their own token service, user defaults, and library file.
    init(
        tokens: HardcoverTokenStore = HardcoverTokenStore(), client: HardcoverClient? = nil,
        defaults: UserDefaults = .standard, libraryURL: URL = PhoneLibrary.url
    ) {
        self.tokens = tokens
        self.defaults = defaults
        self.libraryURL = libraryURL
        #if DEBUG
            let stub = UserDefaults.standard.bool(forKey: "BookwormsStubSignIn")
            self.client =
                client ?? HardcoverClient(transport: stub ? HardcoverClient.debugStub : nil)
        #else
            self.client = client ?? HardcoverClient()
        #endif
        let saved = defaults.data(forKey: Self.summaryKey)
            .flatMap { try? JSONDecoder().decode(Summary.self, from: $0) }
        // The Keychain keeps a login after the app is deleted, and a backup restores the summary
        // and library without the device-only login. Either half alone counts as signed out, so
        // the sheet and `signedInAccountID` agree.
        isSignedIn = tokens.read() != nil && saved != nil
        summary = saved
        if !isSignedIn {
            tokens.delete()
            forgetLibrary()
        }
    }

    /// Requests a code, waits for the reader to approve it on Hardcover, and saves the login.
    ///
    /// The `me` query checks the account before the token is saved. Signing in to another
    /// account drops the cached library; reconnecting the same account keeps it until the next
    /// sync. A sign-in already in progress continues, so the code the reader may be entering
    /// stays valid; only a failed or finished sign-in starts over.
    func startSignIn() {
        switch signIn {
        case .requestingCode, .waiting, .connecting: return
        case .failed, nil: break
        }
        signInTask?.cancel()
        signIn = .requestingCode
        signInTask = Task { [client] in
            do {
                // Each step checks for cancellation first, so a replaced or cancelled sign-in
                // whose reply arrives late never overwrites the current state.
                let authorization = try await client.requestDeviceAuthorization()
                try Task.checkCancellation()
                signIn = .waiting(code: authorization.userCode, url: authorization.pageURL)
                let token = try await HardcoverClient.awaitApproval(of: authorization) {
                    try await client.pollToken(deviceCode: authorization.deviceCode)
                }
                try Task.checkCancellation()
                signIn = .connecting
                let user = try await client.account(token: token)
                try Task.checkCancellation()
                try tokens.save(token)
                let accountID = String(user.id)
                if summary?.accountID != accountID { PhoneLibrary.delete(at: libraryURL) }
                save(Summary(accountID: accountID, username: user.username))
                isSignedIn = true
                needsReconnect = false
                syncError = nil
                signIn = nil
                libraryChanged()
            } catch {
                if !Task.isCancelled { signIn = .failed(Self.message(for: error)) }
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        signIn = nil
    }

    /// Downloads the account's library and replaces the cache. A failure keeps the cache; a
    /// rejected login sets `needsReconnect`.
    func sync() async {
        guard isSignedIn, !isSyncing, let token = tokens.read() else { return }
        isSyncing = true
        syncError = nil
        let revision = libraryRevision
        let task = Task { [client] in try await client.library(token: token) }
        syncTask = task
        let download = await task.result
        // Sign-out cancels the download and clears `isSyncing`, so a later sync may own it now.
        guard syncTask == task else { return }
        syncTask = nil
        isSyncing = false
        guard revision == libraryRevision else {
            // A sign-in during the download owns the cache now, and the new account's own sync
            // was skipped while this one ran.
            return await syncIfStale()
        }
        do {
            let library = try download.get()
            try library.save(to: libraryURL)
            save(
                Summary(
                    accountID: library.accountID, username: library.username,
                    syncedAt: library.syncedAt))
            libraryChanged()
        } catch {
            syncError = Self.message(for: error)
            if [.invalidToken, .insufficientScope].contains(error as? HardcoverError) {
                needsReconnect = true
            }
        }
    }

    /// Syncs when the cached library is missing or older than `staleInterval`.
    func syncIfStale() async {
        guard isSignedIn, !needsReconnect else { return }
        if let syncedAt = summary?.syncedAt, -syncedAt.timeIntervalSinceNow < Self.staleInterval,
            FileManager.default.fileExists(atPath: libraryURL.path())
        {
            return
        }
        await sync()
    }

    /// Deletes the saved login and the cached library from this iPhone and stops a download in
    /// progress. Hardcover is unchanged.
    func signOut() {
        cancelSignIn()
        syncTask?.cancel()
        syncTask = nil
        isSyncing = false
        tokens.delete()
        isSignedIn = false
        needsReconnect = false
        syncError = nil
        forgetLibrary()
        libraryChanged()
    }

    private func forgetLibrary() {
        PhoneLibrary.delete(at: libraryURL)
        summary = nil
        defaults.removeObject(forKey: Self.summaryKey)
    }

    private func save(_ summary: Summary) {
        self.summary = summary
        defaults.set(try? JSONEncoder().encode(summary), forKey: Self.summaryKey)
    }

    private func libraryChanged() {
        libraryRevision += 1
        onLibraryChange?()
    }

    private static func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// The signed-in account's Hardcover library, cached on this iPhone.
///
/// The file lives in `Caches/Bookworms`: it holds private reading history that Hardcover can
/// always provide again, so iOS may evict it and it is never backed up.
struct PhoneLibrary: Codable, Equatable, Sendable {
    /// The Hardcover user ID as a string, the same account ID the Apple TV uses.
    let accountID: String
    let username: String?
    let syncedAt: Date
    let books: [CloudBook]

    /// Named for its format: books gained `isRead`, so a copy saved before then is not read, and
    /// the next sync downloads the library again.
    static let url = URL.cachesDirectory.appending(path: "Bookworms/hardcover-library-2.json")

    /// Returns the cached library, or `nil` when signed out or before the first sync.
    static func load() -> PhoneLibrary? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PhoneLibrary.self, from: data)
    }

    func save(to url: URL = Self.url) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    static func delete(at url: URL = Self.url) {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Keeps the Hardcover access token in this device's Keychain.
///
/// The item is readable after the first unlock, never synchronizable, and does not move to
/// another device through a backup. Tests pass their own service name.
struct HardcoverTokenStore: Sendable {
    var service = "gay.ian.Bookworms.iOS.hardcover"

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "access-token",
            kSecAttrSynchronizable as String: false,
        ]
    }

    func read() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ token: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw HardcoverError.credentialNotSaved }
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
