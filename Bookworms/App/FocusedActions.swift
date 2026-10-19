import SwiftUI

// What the Mac's menu commands act on in the key window.
//
// A view publishes a value with `focusedSceneValue(_:_:)` while it can act, passing `nil`
// otherwise, and a `Commands` type reads it with `@FocusedValue`, so its command acts on the
// window in front and dims while nothing publishes. Each area keeps its commands in a `Commands`
// type in its own file, registered with one line in `BookwormsApp`'s `commands`. An area adds
// to a system menu with `CommandGroup(after:)` or `CommandGroup(replacing:)`; the app's own
// **Go** menu stays in `BookwormsCommands`, so add **Go** items there. Declare every key here.
//
// The values are published on the iPhone too, where nothing reads them.
extension FocusedValues {
    /// Closes the book details showing in the key window: **Go > Back** (Command-[).
    @Entry var goBack: SceneAction?
    /// The book whose details show in the key window.
    @Entry var detailsBook: CloudBook?
    /// The book centered in Library's **Stack** or **Shelf**.
    @Entry var centeredBook: CloudBook?
    /// The image the Share tab's preview shows.
    @Entry var shareImage: ShareImage?
    /// Opens the Hardcover account sheet over the key window.
    @Entry var showAccount: SceneAction?
}

/// An action that a view publishes for a menu command, such as closing the details it shows.
struct SceneAction {
    let perform: @MainActor () -> Void

    @MainActor func callAsFunction() { perform() }
}
