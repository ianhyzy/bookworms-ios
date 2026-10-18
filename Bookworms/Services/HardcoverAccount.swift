import Foundation
import Observation
import Security

/// This device's own Hardcover sign-in: the device-code flow, the saved login, and the library
/// it syncs.
///
/// The login stays in this device's Keychain, and requests renew it with its refresh token
/// before the access token expires and after Hardcover rejects it (`withAccessToken(_:)`). The
/// library goes to the `PhoneLibrary` cache, which `CloudSpineStore` reads to show and design
/// the account's books. The saved
/// `Summary` marks the sign-in for the store (`signedInAccountID`). After a sign-in, sync,
/// adoption, or sign-out changes that cache, `libraryRevision` increases and `onLibraryChange`
/// runs.
///
/// No device owns the library. Any Apple device that downloads it from Hardcover publishes it to
/// the shared `library-v1` archive in iCloud (`cloud`), and `syncIfStale()` adopts a newer copy
/// from there before it asks Hardcover, so the account's library is downloaded about once a day
/// across all of the reader's devices.
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

    /// How old the copy on this device gets before `syncIfStale()` looks for a newer one in
    /// iCloud, and how long it then waits before looking again. A download that is due
    /// (`providerInterval`) looks first regardless.
    static let cloudCheckInterval: TimeInterval = 4 * 60 * 60
    /// How old the newest copy, on this device or in iCloud, gets before `syncIfStale()`
    /// downloads the library from Hardcover. **Sync now** downloads it at any time.
    static let providerInterval: TimeInterval = 24 * 60 * 60
    /// How soon before the access token expires a request renews the login, so a long download
    /// or comparison finishes with a valid token.
    static let renewalMargin: TimeInterval = 60 * 60

    private(set) var isSignedIn = false
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
    /// The store that holds the shared `library-v1` archive, or `nil` in preview mode, where the
    /// account neither reads nor publishes iCloud copies.
    @ObservationIgnored var cloud: (any SpineStore)?
    /// The upload of the last downloaded library to `cloud`, which nothing waits for except
    /// tests. A failed upload is dropped; other devices then download the library themselves.
    @ObservationIgnored private(set) var publishTask: Task<Void, Never>?

    @ObservationIgnored private let tokens: any SecretStore
    /// Whether the Keychain refused the last read of the login, so the login and summary stay
    /// until a read succeeds (`retryUnreadLogin()`).
    @ObservationIgnored private var loginIsUnread = false
    /// The saved login, decoded when `restoreLogin()` reads it or a sign-in or renewal saves it,
    /// so requests never read the Keychain. `nil` while signed out or unread.
    @ObservationIgnored private var cachedCredential: HardcoverCredential?
    /// The renewal in progress. Every request that needs a new access token meanwhile awaits it,
    /// so only one request spends the refresh token.
    @ObservationIgnored private var renewal: Task<HardcoverCredential, any Error>?
    @ObservationIgnored private let client: HardcoverClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let libraryURL: URL
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var syncTask:
        Task<(library: PhoneLibrary, publishes: Bool), any Error>?
    /// When `syncIfStale()` last read the iCloud archive in this session.
    @ObservationIgnored private var lastCloudCheck: Date?
    nonisolated static let summaryKey = "HardcoverAccount"

    /// Whether this launch keeps a Hardcover login of its own: a preview launch
    /// (`-BookwormsPreviewFolder`), the Debug stub sign-in (`-BookwormsStubSignIn`), or a unit
    /// test run.
    ///
    /// Such a launch keeps its login (`loginStore`), account summary (`summaryDefaults`), and
    /// library (`PhoneLibrary.url`) apart from the reader's, so it never reads, prompts for, or
    /// deletes the reader's own login or library.
    nonisolated static let usesScratchLogin = isScratchLaunch(
        defaults: .standard, environment: ProcessInfo.processInfo.environment)

    /// The Keychain item that holds this launch's Hardcover login.
    nonisolated static let loginStore = KeychainSecret(
        service: usesScratchLogin
            ? "gay.ian.Bookworms.iOS.hardcover.scratch" : "gay.ian.Bookworms.iOS.hardcover")

    /// The user defaults that hold this launch's account summary.
    nonisolated static var summaryDefaults: UserDefaults {
        usesScratchLogin ? UserDefaults(suiteName: "gay.ian.Bookworms.scratch")! : .standard
    }

    /// Whether a launch with these launch arguments and user `defaults` and this process
    /// `environment` keeps a login of its own (`usesScratchLogin`).
    nonisolated static func isScratchLaunch(
        defaults: UserDefaults, environment: [String: String]
    ) -> Bool {
        var stubsSignIn = false
        #if DEBUG
            stubsSignIn = defaults.bool(forKey: "BookwormsStubSignIn")
        #endif
        return stubsSignIn || defaults.string(forKey: "BookwormsPreviewFolder") != nil
            || environment["XCTestConfigurationFilePath"] != nil
    }

    /// The signed-in account's ID, or `nil` when signed out. Readable from any isolation.
    ///
    /// `CloudSpineStore` chooses the library source from this rather than from the library
    /// cache, which iOS may evict, so a signed-in iPhone never falls back to the iCloud
    /// archive's newest library, which may belong to another account.
    nonisolated static var signedInAccountID: String? {
        summaryDefaults.data(forKey: summaryKey)
            .flatMap { try? JSONDecoder().decode(Summary.self, from: $0) }?
            .accountID
    }

    /// Tests pass their own token store, user defaults, and library file.
    init(
        tokens: any SecretStore = HardcoverAccount.loginStore, client: HardcoverClient? = nil,
        defaults: UserDefaults = HardcoverAccount.summaryDefaults,
        libraryURL: URL = PhoneLibrary.url
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
        restoreLogin()
    }

    /// Restores the saved login and its account summary.
    ///
    /// The Keychain keeps a login after the app is deleted, and a backup restores the summary
    /// and library without the device-only login. Either half alone counts as signed out and is
    /// deleted, so the sheet and `signedInAccountID` agree. When the Keychain refuses the read,
    /// as before the first unlock after a restart, nothing is deleted: the summary alone marks
    /// the sign-in until a read succeeds (`retryUnreadLogin()`).
    private func restoreLogin() {
        let saved = defaults.data(forKey: Self.summaryKey)
            .flatMap { try? JSONDecoder().decode(Summary.self, from: $0) }
        summary = saved
        cachedCredential = nil
        do {
            let stored = try tokens.load()
            loginIsUnread = false
            isSignedIn = stored != nil && saved != nil
            if isSignedIn {
                cachedCredential = stored.map(HardcoverCredential.init(stored:))
            } else {
                tokens.delete()
                forgetLibrary()
            }
        } catch {
            loginIsUnread = true
            isSignedIn = saved != nil
        }
    }

    /// Reads the saved login again when the Keychain refused the last read, and reports a
    /// changed sign-in as a library change.
    ///
    /// **Sync now** (`sync()`) calls this, and so does the iPhone app when it becomes active
    /// (`AppModel.reloadIfStale()`). Requests in between fail without reading the Keychain
    /// (`savedCredential()`), so one refused read never turns into a series of a Mac's prompts.
    func retryUnreadLogin() {
        guard loginIsUnread else { return }
        let before = (isSignedIn, summary)
        restoreLogin()
        if before != (isSignedIn, summary) { libraryChanged() }
    }

    /// Returns the saved login for an explicit request from `cachedCredential`, without reading
    /// the Keychain. Callers use it for that request and do not keep it.
    ///
    /// Throws `HardcoverError.invalidToken` when signed out, and
    /// `HardcoverError.credentialUnreadable` when the Keychain refused the last read, which only
    /// `retryUnreadLogin()` repeats; the login then stays saved.
    private func savedCredential() throws -> HardcoverCredential {
        guard !loginIsUnread else { throw HardcoverError.credentialUnreadable }
        guard isSignedIn, let cachedCredential else { throw HardcoverError.invalidToken }
        return cachedCredential
    }

    /// Returns an access token for an explicit request, renewing the login first when the token
    /// expires within `renewalMargin`. Callers use it for that request and do not keep it.
    ///
    /// Throws `HardcoverError.invalidToken` when signed out or Hardcover rejected the refresh
    /// token, which also sets `needsReconnect`, and `HardcoverError.credentialUnreadable` while
    /// the Keychain refuses the read. When the renewal that this call starts or waits for fails
    /// another way, as without a network connection, returns the current token until it
    /// expires.
    func accessToken() async throws -> String {
        let credential = try savedCredential()
        do {
            if let renewal { return try await renewal.value.accessToken }
            guard credential.refreshToken != nil, let expiresAt = credential.expiresAt,
                expiresAt.timeIntervalSinceNow < Self.renewalMargin
            else { return credential.accessToken }
            return try await renew(credential).accessToken
        } catch {
            guard let expiresAt = credential.expiresAt, expiresAt > .now, !needsReconnect,
                !(error is CancellationError)
            else { throw error }
            return credential.accessToken
        }
    }

    /// Runs `request` with an access token (`accessToken()`). When Hardcover rejects the token,
    /// renews the login, unless another request already did, and runs `request` once more with
    /// the new token.
    func withAccessToken<Value>(
        _ request: @MainActor (String) async throws -> Value
    ) async throws -> Value {
        let token = try await accessToken()
        do {
            return try await request(token)
        } catch HardcoverError.invalidToken {
            return try await request(renewedToken(replacing: token))
        }
    }

    /// Returns an access token to replace `rejected`: the saved one when another request
    /// already renewed the login, or a renewed one.
    private func renewedToken(replacing rejected: String) async throws -> String {
        if let renewal { return try await renewal.value.accessToken }
        let credential = try savedCredential()
        guard credential.accessToken == rejected else { return credential.accessToken }
        return try await renew(credential).accessToken
    }

    /// Spends `credential`'s refresh token, saves the new login, and returns it.
    ///
    /// Every caller while the renewal runs awaits the same one (`renewal`). A sign-out or new
    /// sign-in cancels it; a cancelled renewal saves nothing and throws `CancellationError`. A
    /// rejected refresh token sets `needsReconnect` and keeps the saved login, and a network or
    /// server failure keeps it for the next request. When the rotated login can't be saved,
    /// this throws `HardcoverError.credentialNotSaved` and sets `needsReconnect`, and while it
    /// is set, no renewal sends the saved refresh token, which Hardcover has already spent.
    private func renew(_ credential: HardcoverCredential) async throws -> HardcoverCredential {
        guard !needsReconnect, let refreshToken = credential.refreshToken else {
            throw HardcoverError.invalidToken
        }
        let task = Task { [client] in
            do {
                let renewed = try await client.renew(refreshToken: refreshToken)
                try Task.checkCancellation()
                do {
                    try tokens.save(renewed.stored())
                } catch {
                    needsReconnect = true
                    throw HardcoverError.credentialNotSaved
                }
                cachedCredential = renewed
                return renewed
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if error as? HardcoverError == .invalidToken { needsReconnect = true }
                throw error
            }
        }
        renewal = task
        defer { if renewal == task { renewal = nil } }
        return try await task.value
    }

    /// Requests a code, waits for the reader to approve it on Hardcover, and saves the login.
    ///
    /// The `me` query checks the account before the token is saved. Signing in to another
    /// account drops the cached library; reconnecting the same account keeps it and its sync
    /// date, so `syncIfStale()` adopts only a newer iCloud copy and downloads on the usual
    /// schedule. A sign-in already in progress continues, so the code the reader may be entering
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
                let credential = try await HardcoverClient.awaitApproval(of: authorization) {
                    try await client.pollToken(deviceCode: authorization.deviceCode)
                }
                try Task.checkCancellation()
                signIn = .connecting
                let user = try await client.account(token: credential.accessToken)
                try Task.checkCancellation()
                do {
                    try tokens.save(credential.stored())
                } catch {
                    throw HardcoverError.credentialNotSaved
                }
                cachedCredential = credential
                // A renewal of the replaced login must not overwrite this one.
                cancelRenewal()
                let accountID = String(user.id)
                let isSameAccount = summary?.accountID == accountID
                if !isSameAccount { PhoneLibrary.delete(at: libraryURL) }
                save(
                    Summary(
                        accountID: accountID, username: user.username,
                        syncedAt: isSameAccount ? summary?.syncedAt : nil))
                isSignedIn = true
                loginIsUnread = false
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

    /// Downloads the account's library, replaces the cache, and publishes the library to the
    /// iCloud archive (`publishTask`). A failure keeps the cache; a rejected login sets
    /// `needsReconnect`.
    ///
    /// The books keep the covers of the account's newest copy, the cached one or the archive's,
    /// unless an upgrade applies
    /// (`HardcoverClient.coverURLs(edition:book:otherEditions:editionIsInLanguage:previous:)`).
    /// When the archive can't be read and this device has no copy, the download is saved but
    /// not published, so a library whose covers were all picked again never replaces the
    /// account's snapshot there.
    ///
    /// When the Keychain refused the last read of the login, reads it again first
    /// (`retryUnreadLogin()`).
    func sync() async {
        retryUnreadLogin()
        await sync(readsArchive: true)
    }

    /// Downloads the library as `sync()` describes, reading the archive's copy first unless
    /// `readsArchive` is `false`, as when the caller has just read the archive and the cache
    /// holds the account's newest copy.
    private func sync(readsArchive: Bool) async {
        guard isSignedIn, !isSyncing, let accountID = summary?.accountID else { return }
        isSyncing = true
        syncError = nil
        let revision = libraryRevision
        let cached = PhoneLibrary.load(from: libraryURL)
        let username = summary?.username
        let task = Task { [client, cloud] in
            var previous = cached
            var publishes = true
            if readsArchive, let cloud {
                do {
                    if let copy = try await cloud.archivedLibrary(accountID: accountID),
                        copy.syncedAt > cached?.syncedAt ?? .distantPast
                    {
                        previous = PhoneLibrary(copy, username: username)
                    }
                } catch {
                    publishes = cached?.accountID == accountID
                }
            }
            let newest = previous
            let library = try await withAccessToken {
                try await client.library(token: $0, previous: newest)
            }
            return (library: library, publishes: publishes)
        }
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
            let (library, publishes) = try download.get()
            try library.save(to: libraryURL)
            save(
                Summary(
                    accountID: library.accountID, username: library.username,
                    syncedAt: library.syncedAt))
            libraryChanged()
            if publishes {
                publishTask = Task { [cloud] in try? await cloud?.publishLibrary(library) }
            }
        } catch {
            syncError = Self.message(for: error)
            if [.invalidToken, .insufficientScope].contains(error as? HardcoverError) {
                needsReconnect = true
            }
        }
    }

    /// Brings the cached library up to date, from iCloud when another device downloaded it
    /// recently.
    ///
    /// Reads the account's newest snapshot in the iCloud archive, and adopts it when it is
    /// newer, before every download from Hardcover that is due, and otherwise without a cached
    /// library or once it is `cloudCheckInterval` old and the archive was not read for as long.
    /// Adoption needs no Hardcover login, so it works while `needsReconnect` is set. Then
    /// downloads the library from Hardcover (`sync()`) only when the newest copy is
    /// `providerInterval` old, which includes every case where iCloud is unavailable. A
    /// sign-in, sign-out, or sync that changes the library during the iCloud read starts the
    /// check again for the current account.
    func syncIfStale() async {
        guard isSignedIn, let accountID = summary?.accountID else { return }
        var newest =
            FileManager.default.fileExists(atPath: libraryURL.path()) ? summary?.syncedAt : nil
        let isDue = newest.map { isOlder($0, than: Self.providerInterval) } ?? true
        // A device that needs a new login can't download, so it keeps the slower cadence.
        let checksCloud =
            (isDue && !needsReconnect)
            || newest.map {
                isOlder($0, than: Self.cloudCheckInterval)
                    && lastCloudCheck.map { isOlder($0, than: Self.cloudCheckInterval) } ?? true
            } ?? true
        var archiveWasRead = false
        if let cloud, checksCloud {
            let revision = libraryRevision
            var copy: CloudSourceSnapshot?
            do {
                copy = try await cloud.archivedLibrary(accountID: accountID)
                archiveWasRead = true
            } catch {}
            guard !isSyncing else { return }
            guard revision == libraryRevision else { return await syncIfStale() }
            // Only a read that finished for the current library counts, so a failed read, or one
            // a sign-in overtook, doesn't delay the next check by `cloudCheckInterval`.
            if archiveWasRead { lastCloudCheck = .now }
            if let copy, copy.syncedAt > newest ?? .distantPast {
                let library = PhoneLibrary(copy, username: summary?.username)
                if (try? library.save(to: libraryURL)) != nil {
                    save(
                        Summary(
                            accountID: accountID, username: library.username,
                            syncedAt: library.syncedAt))
                    newest = library.syncedAt
                    libraryChanged()
                }
            }
        }
        guard !needsReconnect, newest.map({ isOlder($0, than: Self.providerInterval) }) ?? true
        else { return }
        await sync(readsArchive: !archiveWasRead)
    }

    private func isOlder(_ date: Date, than interval: TimeInterval) -> Bool {
        -date.timeIntervalSinceNow >= interval
    }

    /// Deletes the saved login and the cached library from this device and stops a download in
    /// progress. Hardcover is unchanged, and so is the copy this device published to iCloud,
    /// which the signed-out app shows when it is the archive's newest Hardcover library.
    func signOut() {
        cancelSignIn()
        syncTask?.cancel()
        syncTask = nil
        isSyncing = false
        cancelRenewal()
        tokens.delete()
        cachedCredential = nil
        isSignedIn = false
        loginIsUnread = false
        needsReconnect = false
        syncError = nil
        forgetLibrary()
        libraryChanged()
    }

    private func cancelRenewal() {
        renewal?.cancel()
        renewal = nil
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

/// The signed-in account's Hardcover library, cached on this device.
///
/// The file lives in `Caches/Bookworms`: it holds private reading history that Hardcover or the
/// iCloud archive can always provide again, so the system may evict it and it is never backed
/// up.
struct PhoneLibrary: Codable, Equatable, Sendable {
    /// The Hardcover user ID as a string, the same account ID the Apple TV uses.
    let accountID: String
    let username: String?
    let syncedAt: Date
    let books: [CloudBook]
    /// The series of the books, which the Apple TV shows in book details, or `nil` when they
    /// weren't downloaded. `CloudSpineStore.publishLibrary(_:)` writes them with the library.
    var series: [SeriesInfo]? = nil

    /// Named for its format: books gained `seriesMemberships`, so a copy saved before then is not
    /// read, and the next sync downloads the library again. A launch with a login of its own
    /// (`HardcoverAccount.usesScratchLogin`) keeps its copy in a folder of its own.
    static let url = URL.cachesDirectory.appending(
        path: HardcoverAccount.usesScratchLogin
            ? "Bookworms/Scratch/hardcover-library-5.json" : "Bookworms/hardcover-library-5.json")

    /// Returns the cached library, or `nil` when signed out or before the first sync.
    static func load(from url: URL = Self.url) -> PhoneLibrary? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PhoneLibrary.self, from: data)
    }

    func save(to url: URL = Self.url) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// Deletes the cached library at `url` and the copies that earlier formats left beside it,
    /// which hold the same reading history.
    static func delete(at url: URL = Self.url) {
        try? FileManager.default.removeItem(at: url)
        let folder = url.deletingLastPathComponent()
        for old in [
            "hardcover-library.json", "hardcover-library-2.json", "hardcover-library-3.json",
            "hardcover-library-4.json",
        ] {
            try? FileManager.default.removeItem(at: folder.appending(path: old))
        }
    }
}

extension PhoneLibrary {
    /// The account's snapshot from the iCloud archive, as this device caches it.
    init(_ copy: CloudSourceSnapshot, username: String?) {
        self.init(
            accountID: copy.accountID, username: username, syncedAt: copy.syncedAt,
            books: copy.books, series: copy.series)
    }
}

/// Keeps one secret string. `KeychainSecret` keeps it in this device's Keychain; tests use
/// stores of their own.
protocol SecretStore {
    /// Returns the secret, or `nil` when none is saved. Throws when the store refuses the read;
    /// the secret may still exist.
    func load() throws -> String?
    func save(_ secret: String) throws
    func delete()
}

/// Keeps one secret, such as the Hardcover login or an AI provider's API key, in this device's
/// Keychain.
///
/// The item is readable after the first unlock, never synchronizable, and does not move to
/// another device through a backup. Tests pass their own service name.
struct KeychainSecret: SecretStore, Sendable {
    /// The Keychain refused to save the secret.
    struct NotSaved: Error {}
    /// The Keychain refused to read the secret, as it does before the first unlock after a
    /// restart (`errSecInteractionNotAllowed`) or after the reader declines a Mac's prompt. The
    /// item may still exist.
    struct Unreadable: Error {
        let status: OSStatus
    }

    var service = "gay.ian.Bookworms.iOS.hardcover"
    var account = "access-token"

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    /// Returns the secret, or `nil` when none is saved or the Keychain refuses the read.
    func read() -> String? { try? load() }

    func load() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw Unreadable(status: status)
        }
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
        guard status == errSecSuccess else { throw NotSaved() }
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
