import XCTest

@testable import Bookworms

/// The reader's consent for third-party providers (`SpineDesigner.hasConsent(of:)`) in the tests'
/// own defaults.
enum ProviderConsent {
    private static let providers = SpineDesigner.Provider.allCases.filter { $0 != .apple }

    /// Records consent for every third-party provider, as a reader who chose **Allow** for each.
    static func allowAll() {
        providers.forEach(SpineDesigner.allow)
    }

    /// Forgets every provider's consent, as deleting the app does.
    static func forget() {
        let tests = UserDefaults(suiteName: "gay.ian.Bookworms.tests")
        for provider in providers {
            tests?.removeObject(forKey: "SpineDesignerConsent.\(provider.rawValue)")
        }
    }
}

extension XCTestCase {
    /// Lets this test's requests reach third-party providers, which get none without the
    /// reader's consent, and forgets the consent when the test ends.
    func allowThirdPartyProviders() {
        ProviderConsent.allowAll()
        addTeardownBlock { ProviderConsent.forget() }
    }
}
