import SwiftUI

// What the Mac's menu commands act on in the key window.
//
// A view publishes a value with `focusedSceneValue(_:_:in:)` while it can act, passing `nil`
// otherwise, and a `Commands` type reads it with `@FocusedValue`, so its command acts on the
// window in front and dims while nothing publishes. Each area keeps its commands in a `Commands`
// type in its own file, registered with one line in `BookwormsApp`'s `commands`. An area adds
// to a system menu with `CommandGroup(after:)` or `CommandGroup(replacing:)`; the app's own
// **Go** menu stays in `BookwormsCommands`, so add **Go** items there. Declare every key here.
//
// Publish only values that change at the pace of a person's choices. Every change rebuilds the
// commands that read the key and updates the menu bar.
//
// The values are published on the iPhone too, where nothing reads them.
extension FocusedValues {
    /// Closes the book details showing in the key window: **Go > Back** (Command-[).
    @Entry var goBack: SceneAction?
    /// The book whose details show in the key window.
    @Entry var detailsBook: CloudBook?
    /// The book centered in Library's **Stack** or **Shelf**.
    ///
    /// Publish it once scrolling settles, not as each book passes the center during a fling.
    @Entry var centeredBook: CloudBook?
    /// Copies the Share tab's image with its credit: **Edit > Copy Image**.
    @Entry var copyShareImage: SceneAction?
    /// Saves the Share tab's image to a file: **File > Save Image…** (Command-S).
    @Entry var saveShareImage: SceneAction?
    /// Shows the Share tab's image full size in Quick Look: **View > Quick Look** (Command-Y).
    @Entry var previewShareImage: SceneAction?
    /// Opens the Hardcover account sheet over the key window.
    @Entry var showAccount: SceneAction?
    /// What the **Library** and **View** menus act on while Library shows its books.
    @Entry var libraryActions: LibraryActions?
}

/// An action that a view publishes for a menu command, such as closing the details it shows.
struct SceneAction {
    let perform: @MainActor () -> Void

    @MainActor func callAsFunction() { perform() }
}

extension View {
    /// Publishes `value` for `key` while `tab` is the selected tab, and `nil` while another tab
    /// shows.
    ///
    /// The tab view keeps hidden tabs' views, such as Library's details while their **Share**
    /// shows the Share tab, or details pushed in Library and in Desk. Publish through this rather
    /// than `focusedSceneValue(_:_:)`, so that a hidden tab never answers a command meant for the
    /// one in front.
    func focusedSceneValue<Value>(
        _ key: WritableKeyPath<FocusedValues, Value?>, _ value: Value?, in tab: AppTab
    ) -> some View {
        modifier(TabFocusedValue(key: key, value: value, tab: tab))
    }
}

/// Reads the selected tab in a modifier of its own, so a tab switch updates only the published
/// value, not the body of the view that publishes it.
private struct TabFocusedValue<Value>: ViewModifier {
    let key: WritableKeyPath<FocusedValues, Value?>
    let value: Value?
    let tab: AppTab
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.focusedSceneValue(key, model.selectedTab == tab ? value : nil)
    }
}
