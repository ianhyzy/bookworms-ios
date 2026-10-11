import RealityKit
import SwiftUI

/// The pile view's full size, under the bars, and the insets of the bars that cover its edges.
struct PileViewport: Equatable {
    var size: CGSize
    var insets: EdgeInsets
}

/// The library as a physics toy: the first `maximumBooks` books drop onto a table and pile up.
///
/// Drag a book to pick it up and throw it, tap one for its details, pinch to zoom, and turn two
/// fingers to look around the pile. Tilting the phone tips the table, when the phone reports
/// motion and the shelf's **Tilt to move books** is on. With Reduce Motion on, books appear in
/// tidy stacks instead of falling, and tilt is off. The table fills the screen, but walls keep
/// the books between the bars.
///
/// Returning from a book's details finds the pile as the reader left it. Leaving it any other
/// way, such as for another tab, frees its books and textures, and the books drop again on the
/// reader's return. **Share** makes an image of all `books` in a new pile, headed `title`.
/// While its sheet is open, the pile leaves the screen and keeps its books, and tilt pauses,
/// as it does while the app is not active.
///
/// RealityKit's render thread can crash drawing this view while a share image's offscreen
/// renderer steps the same engine, so while any pile image renders, such as the Share tab's
/// Pile template, the table and books leave the view's scene. RealityKit keeps updating a
/// `RealityView` in a tab that is not selected, and a view removed there lingers until its tab
/// shows again and then takes its scene along, so the view itself stays.
struct BookPileView: View {
    /// The most books the pile drops. Tall enough stacks of more would reach the ceiling, and
    /// their textures would outgrow the memory `BookPileScene` budgets for.
    static let maximumBooks = 300

    let books: [CloudBook]
    /// The name of the books' time frame, which heads the share image.
    let title: String
    let open: (CloudBook) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    /// Set by **Tilt to move books** in the shelf's **Sort and filter** menu.
    @AppStorage("BookwormsPileTilt") private var tilts = true
    @State private var scene = BookPileScene()
    @State private var viewport: PileViewport?
    /// Counts **Drop again** presses; each starts a new drop with new poses.
    @State private var generation = 0
    /// Set while a book's details cover the pile.
    @State private var showsBook = false
    @State private var sharesPile = false
    /// Set while a finger holds a book. SwiftUI resets it when the drag ends or is cancelled,
    /// so the book is let go either way.
    @GestureState private var holdsBook = false
    /// Set while fingers zoom or turn the camera, and reset like `holdsBook`, so the next
    /// gesture starts from the camera as it is.
    @GestureState private var movesCamera = false

    private struct DropRequest: Equatable {
        let ids: [Int]
        let tidy: Bool
        let generation: Int
        let viewport: PileViewport?
    }

    var body: some View {
        let dropped = Array(books.prefix(Self.maximumBooks))
        ZStack {
            if sharesPile {
                Color.clear
            } else {
                RealityView { content in
                    content.camera = .virtual
                    content.renderingEffects.antialiasing = .multisample4X
                    scene.attach(to: &content)
                    if PileSnapshotRenderer.isRendering { scene.root.removeFromParent() }
                } update: { content in
                    // Puts back what a finished render took out of the scene.
                    if !PileSnapshotRenderer.isRendering && scene.root.scene == nil {
                        content.add(scene.root)
                    }
                }
                .gesture(throwBook)
                .gesture(openBook)
                .simultaneousGesture(moveCamera)
            }
        }
        .ignoresSafeArea()
        // Outside `ignoresSafeArea`, the proxy reports the safe area's size and the insets the
        // view extends past.
        .onGeometryChange(for: PileViewport.self) { proxy in
            let insets = proxy.safeAreaInsets
            return PileViewport(
                size: CGSize(
                    width: proxy.size.width + insets.leading + insets.trailing,
                    height: proxy.size.height + insets.top + insets.bottom),
                insets: insets)
        } action: {
            viewport = $0
        }
        .task(
            id: DropRequest(
                ids: dropped.map(\.id), tidy: reduceMotion, generation: generation,
                viewport: viewport)
        ) {
            guard let viewport else { return }
            await scene.fill(
                dropped, tidy: reduceMotion, generation: generation, viewport: viewport,
                model: model)
        }
        .onAppear {
            showsBook = false
            scene.setTilt(tracksTilt)
            #if DEBUG
                if PileSnapshotDebug.opensSheet { sharesPile = true }
            #endif
        }
        .onDisappear {
            scene.endDrag()
            scene.setTilt(false)
            if !showsBook { scene.release() }
        }
        // Leaves the view nothing to draw while a share image renders, in whichever tab.
        .onChange(of: PileSnapshotRenderer.isRendering) { _, isRendering in
            if isRendering { scene.root.removeFromParent() }
        }
        // Stops sampling motion while nothing reads it, and takes a new reference afterward.
        .onChange(of: tracksTilt) { scene.setTilt(tracksTilt) }
        .onChange(of: holdsBook) { if !holdsBook { scene.endDrag() } }
        .onChange(of: movesCamera) { if !movesCamera { scene.endCameraMove() } }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(dropTitle, systemImage: "arrow.counterclockwise") { generation += 1 }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Share", systemImage: "square.and.arrow.up") { sharesPile = true }
            }
            // Names the time frame, which the toolbar's menu saves across launches.
            ToolbarItem(placement: .subtitle) {
                Text("\(title) · \(count)")
            }
        }
        .sheet(isPresented: $sharesPile) { PileSnapshotSheet(books: books, title: title) }
        .accessibilityElement()
        .accessibilityLabel("Pile of \(count)")
        .accessibilityValue(title)
        .accessibilityHint(
            "Drag a book to throw it, or tap one for its details. To go through books one at a time, choose Stack or Shelf."
        )
        .accessibilityAction(named: dropTitle) { generation += 1 }
    }

    private var tiltIsOn: Bool { tilts && !reduceMotion }
    private var tracksTilt: Bool { tiltIsOn && !sharesPile && scenePhase == .active }

    /// The number of books, such as "39 books", or "300 of 1,024 books" past `maximumBooks`.
    private var count: String {
        if books.count > Self.maximumBooks {
            return "\(Self.maximumBooks) of \(books.count.formatted()) books"
        }
        return books.count == 1 ? "1 book" : "\(books.count.formatted()) books"
    }

    private var dropTitle: String { reduceMotion ? "Stack again" : "Drop again" }

    private var throwBook: some Gesture {
        DragGesture(minimumDistance: 6)
            .targetedToAnyEntity()
            .updating($holdsBook) { _, holds, _ in holds = true }
            .onChanged { value in
                scene.drag(
                    value.entity, along: value.ray(through: value.location, in: .local, to: .scene))
            }
    }

    private var openBook: some Gesture {
        SpatialTapGesture()
            .targetedToAnyEntity()
            .onEnded { value in
                guard let id = scene.bookID(for: value.entity),
                    let book = books.first(where: { $0.id == id })
                else { return }
                showsBook = true
                open(book)
            }
    }

    private var moveCamera: some Gesture {
        MagnifyGesture()
            .simultaneously(with: RotateGesture())
            .updating($movesCamera) { _, moves, _ in moves = true }
            .onChanged { value in
                scene.moveCamera(
                    magnification: value.first?.magnification ?? 1,
                    rotation: value.second?.rotation ?? .zero, focus: value.first?.startLocation,
                    in: viewport?.size ?? .zero)
            }
    }
}

extension TimeFrame {
    /// The frame a setting names: "year:2025", "month:2025-8", or "lifetime".
    init?(setting: String) {
        let parts = setting.split(separator: ":", maxSplits: 1).map(String.init)
        let numbers = parts.dropFirst().first?.split(separator: "-").compactMap { Int($0) } ?? []
        switch (parts.first, numbers.count) {
        case ("year", 1): self = .year(numbers[0])
        case ("month", 2) where (1...12).contains(numbers[1]):
            self = .month(year: numbers[0], month: numbers[1])
        case ("lifetime", 0) where parts.count == 1: self = .lifetime
        default: return nil
        }
    }

    /// The frame as `init(setting:)` reads it.
    var setting: String {
        switch self {
        case .year(let year): "year:\(year)"
        case .month(let year, let month): "month:\(year)-\(month)"
        case .lifetime: "lifetime"
        }
    }

    /// The pile's frame for a saved setting, or `nil` for every book.
    ///
    /// A saved year or month in which no book was finished, such as one from another library,
    /// gives way to the newest year or month that has one, so the pile keeps the reader's kind
    /// of frame.
    static func pileFrame(setting: String, in books: [CloudBook]) -> TimeFrame? {
        guard let saved = TimeFrame(setting: setting) else { return nil }
        let periods = periods(in: books)
        switch saved {
        case .year(let year) where !periods.years.contains(year):
            return periods.years.first.map(TimeFrame.year)
        case .month where !periods.months.contains(saved): return periods.months.first
        default: return saved
        }
    }
}
