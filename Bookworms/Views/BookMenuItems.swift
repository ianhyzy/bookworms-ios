import SwiftUI

/// A book's context menu items: **Open**, **Make Share Image**, **Change Cover…** (**Change
/// Series Cover…** for a series that shares a design), **Redesign Spine** (or **Spines**), and
/// **Copy Title**. The view that shows the book opens it and presents the cover picker; the
/// rest act through the app's models, as the same buttons in a book's details do.
struct BookMenuItems: View {
    let book: CloudBook
    let open: (CloudBook) -> Void
    let changeCover: (CloudBook) -> Void

    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation

    var body: some View {
        let series = model.sharesSeriesDesign(book)
        Button("Open", systemImage: "book") { open(book) }
        Button("Make Share Image", systemImage: "rectangle.portrait.on.rectangle.portrait") {
            model.share(book)
        }
        Divider()
        Button(
            series ? "Change Series Cover…" : "Change Cover…", systemImage: "photo.on.rectangle"
        ) { changeCover(book) }
        Button(series ? "Redesign Spines" : "Redesign Spine", systemImage: "wand.and.sparkles") {
            generation.redesign(book)
        }
        // One run designs at a time, as the details' button says.
        .disabled(generation.status.isRunning)
        Divider()
        Button("Copy Title", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = book.title
        }
    }
}
