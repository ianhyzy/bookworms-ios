#if os(macOS)
    import SwiftUI

    /// The menu bar's Library commands, which Library's toolbar mirrors:
    ///
    /// - **View**: **as Stack** and **as Shelf** (Control-Command-1 and Control-Command-2),
    ///   **3D Books** for Stack, and the **Time** and **Sort By** menus, bound to the same saved
    ///   settings as the toolbar's controls.
    /// - **File**: **Open in New Window** (Option-Command-O) for the centered book
    ///   (`BookWindow`), in place of the book windows' **New** item, which would open a window
    ///   for no book.
    /// - **Library**: **Find Book…** (Command-F); for the centered book, **Open** (Command-O),
    ///   **Make Share Image**, **Change Cover…**, **Redesign Spine**, and **Copy Title**
    ///   (`BookMenu`); then **Sync Library** (Command-R), **Generate Spines** or **Stop
    ///   Generating** (Shift-Command-G), and **Hardcover Account…**.
    ///
    /// The View commands and the book commands work while Library shows its books, which
    /// publishes what they act on (`LibraryActions`), and the book commands act on the centered
    /// book once scrolling settles (`FocusedValues.centeredBook`).
    struct LibraryCommands: Commands {
        let model: AppModel
        let generation: GenerationController

        @FocusedValue(\.libraryActions) private var actions
        @FocusedValue(\.centeredBook) private var book
        @FocusedValue(\.showAccount) private var showAccount
        @Environment(\.openWindow) private var openWindow
        @AppStorage("BookwormsShelfMode") private var mode = ShelfMode.stack
        @AppStorage("BookwormsStackStyle") private var stackStyle = StackStyle.flat
        @AppStorage("BookwormsLibraryTime") private var time = LibraryTime.last12Months
        @AppStorage("BookwormsShelfSort") private var sort = ShelfSort.finished

        var body: some Commands {
            CommandGroup(replacing: .newItem) {
                Button("Open in New Window") {
                    if let book { openWindow(id: BookWindow.id, value: book.id) }
                }
                .keyboardShortcut("o", modifiers: [.command, .option])
                .disabled(book == nil || actions == nil)
            }
            CommandGroup(after: .toolbar) {
                Section {
                    Toggle("as Stack", isOn: shows(.stack))
                        .keyboardShortcut("1", modifiers: [.control, .command])
                    Toggle("as Shelf", isOn: shows(.shelf))
                        .keyboardShortcut("2", modifiers: [.control, .command])
                    Toggle(
                        "3D Books",
                        isOn: Binding {
                            stackStyle == .threeD
                        } set: {
                            stackStyle = $0 ? .threeD : .flat
                        }
                    )
                    .disabled(mode != .stack)
                    Picker("Time", selection: $time) {
                        ForEach(LibraryTime.spans, id: \.self) { Text($0.menuTitle).tag($0) }
                        if let years = actions?.years, !years.isEmpty {
                            Divider()
                            ForEach(years, id: \.self) {
                                Text(String($0)).tag(LibraryTime.year($0))
                            }
                        }
                    }
                    Picker("Sort By", selection: $sort) {
                        ForEach(ShelfSort.allCases) { Text($0.menuTitle).tag($0) }
                    }
                }
                .disabled(actions == nil)
            }
            CommandMenu("Library") {
                Button("Find Book…") { actions?.find() }
                    .keyboardShortcut("f")
                    .disabled(actions == nil)
                Divider()
                if let book, let actions {
                    BookMenu(
                        book: book, open: actions.open, changeCover: actions.changeCover,
                        inMenuBar: true
                    )
                    .environment(model)
                    .environment(generation)
                } else {
                    // The same items, dimmed, so the menu keeps its shape.
                    Group {
                        Button("Open") {}.keyboardShortcut("o")
                        Divider()
                        Button("Make Share Image") {}
                        Button("Change Cover…") {}
                        Button("Redesign Spine") {}
                        Divider()
                        Button("Copy Title") {}
                    }
                    .disabled(true)
                }
                Divider()
                Button("Sync Library") { Task { await model.syncLibrary() } }
                    .keyboardShortcut("r")
                    .disabled(model.isSyncingLibrary)
                GenerateButton(idleTitle: "Generate Spines")
                    .environment(generation)
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Hardcover Account…") { showAccount?() }
                    .disabled(showAccount == nil)
            }
        }

        /// Whether Library shows `shown`, which choosing it switches to.
        private func shows(_ shown: ShelfMode) -> Binding<Bool> {
            Binding {
                mode == shown
            } set: {
                if $0 { mode = shown }
            }
        }
    }
#endif
