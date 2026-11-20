import SwiftUI

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// The books the reader dropped in the time frame, drawn in black and white.
///
/// Flat, up to `coverLimit` books show as a grid of covers, and more as stacks of lettered
/// spines. In 3D, the books stand in a wire mesh wastebasket: up to `basketCoverLimit` of
/// them with their covers facing the viewer, or with more than `coverLimit`, every book with
/// its spine. The card draws the newest `maximumBooks`, and its count names every book.
struct DroppedCard: View {
    let input: ShareInput

    /// The most books that show their covers. More show their spines.
    static let coverLimit = 6
    /// The most covers the wastebasket stands, so each stays large: of more books, up to
    /// `coverLimit`, the most popular (`[CloudBook].popular(_:)`).
    static let basketCoverLimit = 4

    /// The most books the card draws. Up to about this many books of typical thickness, two
    /// flat stacks fill the card's width before its height in every aspect, so spines keep the
    /// largest lettering their length allows; each book past it would thin every spine.
    static let maximumBooks = 40

    /// The newest `maximumBooks` of the dropped books, which the card draws.
    var shown: [CloudBook] { Array(input.books.prefix(Self.maximumBooks)) }

    var body: some View {
        let theme = ShareTheme.neutral
        ZStack {
            LinearGradient(
                colors: [theme.backdropLight.color, theme.backdropDark.color],
                startPoint: .top, endPoint: .bottom)
            VStack(spacing: input.aspect == .story ? 56 : 36) {
                VStack(spacing: 10) {
                    ShareStyle.title(heading, aspect: input.aspect)
                    Text(count)
                        .font(ShareStyle.serif(40))
                        .opacity(0.7)
                }
                .foregroundStyle(ShareStyle.cream.color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                GeometryReader { proxy in
                    content(in: proxy.size)
                }
            }
            .padding(input.reachingInsets)
        }
    }

    /// "Dropped in 2025", "Dropped in August 2025", or "Books I dropped".
    private var heading: String {
        input.frame == .lifetime ? "Books I dropped" : "Dropped in \(input.frame.title)"
    }

    var count: String {
        input.books.count == 1
            ? "1 book I didn't finish" : "\(input.books.count) books I didn't finish"
    }

    private var showsCovers: Bool { input.books.count <= Self.coverLimit }

    @ViewBuilder
    private func content(in size: CGSize) -> some View {
        switch (input.coverStyle, showsCovers) {
        case (.flat, true): coverGrid(in: size)
        case (.flat, false): spineStacks(in: size)
        case (.threeD, _): basket(in: size)
        }
    }

    // MARK: - Flat

    /// The covers in up to three columns, as large as the rows allow.
    private func coverGrid(in size: CGSize) -> some View {
        let books = shown
        // At least one column, so that an empty list makes no rows.
        let columns = max(1, books.count <= 2 ? books.count : books.count <= 4 ? 2 : 3)
        let rows = (books.count + columns - 1) / columns
        let gap: CGFloat = 44
        let widest =
            books.map { ShareCover.aspect(of: input.covers[$0.id], style: .flat) }.max() ?? 2 / 3
        let height = min(
            (size.height - gap * CGFloat(rows - 1)) / CGFloat(max(1, rows)),
            (size.width - gap * CGFloat(columns - 1)) / CGFloat(columns) / widest)
        return VStack(spacing: gap) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(books[(row * columns)..<min(books.count, (row + 1) * columns)]) {
                        book in
                        ShareCover(
                            book: book, look: input.look(for: book), cover: input.covers[book.id],
                            style: .flat, height: height
                        )
                        .grayscale(1)
                        .shadow(color: .black.opacity(0.45), radius: 20, y: 14)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    /// The book's size in the 3D views' proportions (`BookShape`): spine to fore edge, tail to
    /// head, and back to front cover.
    private func shape(_ book: CloudBook) -> SIMD3<Float> {
        BookShape(of: book, coverAspect: Book3DView.aspect(of: input.covers[book.id])).size
    }

    /// The books lying flat in up to four stacks, newest on top, in their real proportions:
    /// as many stacks as give the longest spines.
    private func spineStacks(in size: CGSize) -> some View {
        let books = shown
        let shapes = books.map(shape)
        let longest = CGFloat(shapes.map(\.y).max() ?? 1)
        let gap: CGFloat = 48
        // The scale, in pixels per unit of `shape`, that each column count allows.
        let layouts = (1...4)
            .map { columns in
                let stacks = Self.split(Array(books.indices), into: columns)
                let tallest = stacks.map { $0.reduce(0) { $0 + CGFloat(shapes[$1].z) } }.max() ?? 1
                let width = (size.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
                return (stacks: stacks, scale: min(width * 0.95 / longest, size.height / tallest))
            }
        let layout = layouts.max { $0.scale < $1.scale }!
        return HStack(alignment: .bottom, spacing: gap) {
            ForEach(layout.stacks, id: \.self) { stack in
                VStack(spacing: 0) {
                    ForEach(stack, id: \.self) { index in
                        let book = books[index]
                        let length = CGFloat(shapes[index].y) * layout.scale
                        SpineView(book: book, look: input.look(for: book))
                            .frame(width: length, height: CGFloat(shapes[index].z) * layout.scale)
                            .grayscale(1)
                            .flatStackTwist(of: book, seed: input.seed)
                            .offset(
                                x: (ShareStyle.unit(input.seed, book.id, 8) - 0.5) * length * 0.08)
                    }
                }
                .shadow(color: .black.opacity(0.4), radius: 16, y: 10)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .bottom)
    }

    /// Splits `items` into `count` runs of nearly equal length, in order.
    private static func split(_ items: [Int], into count: Int) -> [[Int]] {
        let size = (items.count + count - 1) / count
        return stride(from: 0, to: items.count, by: max(1, size))
            .map {
                Array(items[$0..<min(items.count, $0 + size)])
            }
    }

    // MARK: - Wastebasket

    /// The books in a tall wastebasket whose bottom quarter runs off the card's bottom edge,
    /// past the content's margin. The books are larger than the basket, so they rise well
    /// above its rim. Their bottoms gather below the card's edge, and they fan out against the
    /// rim, like flowers in a vase. A few face the viewer with their covers, and more with
    /// their spines.
    private func basket(in size: CGSize) -> some View {
        let books = showsCovers ? shown.popular(Self.basketCoverLimit) : shown
        let shapes = books.map(shape)
        let longest = CGFloat(shapes.map(\.y).max() ?? 1)
        // How far each book's middle stands out from the fan's middle, in book heights.
        let reach =
            showsCovers
            ? (books.map { Book3DView.aspect(of: input.covers[$0.id]) }.max() ?? 2 / 3) / 2
            : CGFloat(shapes.map(\.z).max() ?? 0) / longest / 2
        let lean = maximumLean(shapes: shapes, longest: longest) * .pi / 180
        // The scene's width and height in book heights.
        let depth: CGFloat = showsCovers ? 0.7 : 0.78
        // Wide enough that the books stay inside the wall, both at the rim and at the card's
        // edge, where the tapered wall is narrower.
        let radius = max(
            showsCovers ? 0.42 : 0.4,
            (footSpread + depth * sin(lean) + reach * cos(lean)) * 1.04,
            (footSpread + reach) / 0.85 * 1.04)
        let width = max(
            2 * (footSpread + sin(lean) + reach * cos(lean)) + 0.06, radius * 2 * 1.08)
        // The card's bottom edge, below the content. On a story, whose width limits the
        // basket, the scene reaches into the side margins.
        let edge = size.height + input.reachingInsets.bottom
        let reaches = input.aspect == .story
        let leading = reaches ? input.reachingInsets.leading : 0
        let full = size.width + leading + (reaches ? input.reachingInsets.trailing : 0)
        let scale = min(full / width, edge)
        // The rim stands low enough that the books' tops rise above it, and three quarters of
        // the basket shows above the card's edge.
        let wall = scale * depth / 0.75
        let basket = Wastebasket(
            center: leading + size.width / 2, bottom: edge + wall * 0.25, radius: scale * radius,
            depth: wall)
        return ZStack(alignment: .topLeading) {
            Canvas { context, _ in basket.drawBack(in: &context) }
            ZStack(alignment: .topLeading) {
                // The outer books stand behind the middle ones.
                let middle = CGFloat(books.count - 1) / 2
                let order = books.indices.sorted {
                    abs(CGFloat($0) - middle) > abs(CGFloat($1) - middle)
                }
                ForEach(order, id: \.self) { index in
                    let book = books[index]
                    // A lone book leans one way.
                    let slot = middle == 0 ? -1 : (CGFloat(index) - middle) / middle
                    let jitter = ShareStyle.unit(input.seed, book.id, 6) - 0.5
                    let length = scale * CGFloat(shapes[index].y) / longest
                    standing(
                        book, length: length,
                        thickness: length * CGFloat(shapes[index].z / shapes[index].y),
                        jitter: jitter
                    )
                    .rotationEffect(
                        .radians(Double(slot) * lean) + .degrees(jitter * 3), anchor: .bottom
                    )
                    .position(
                        x: basket.center + slot * footSpread * scale,
                        y: edge + scale * 0.02 - length / 2)
                }
            }
            .frame(width: full, height: edge, alignment: .topLeading)
            .clipShape(basket.interior(width: full))
            Canvas { context, _ in basket.drawFront(in: &context) }
            // The basket fades into the backdrop above the profile link and credit, which sit
            // on solid backdrop so that no cover shows through their lettering.
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.clear, ShareTheme.neutral.backdropDark.color],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: input.reachingInsets.bottom)
                ShareTheme.neutral.backdropDark.color.frame(height: lettering)
            }
            .frame(width: full, height: edge, alignment: .bottom)
        }
        .frame(width: full, height: edge)
        .offset(x: -leading)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// The height of the solid band at the card's bottom edge that holds the profile link, or
    /// the credit alone when there is no link.
    private var lettering: CGFloat {
        guard input.username != nil else { return ShareCredit.height }
        return ShareProfileLink.bottom(input.aspect) + ShareProfileLink.fontSize * 1.4
    }

    /// How far the outermost books' bottoms stand from the middle of the base, in book heights.
    /// Covers are wide, so they stand close together.
    private var footSpread: CGFloat { showsCovers ? 0.04 : 0.14 }

    /// The most the outermost book leans, in degrees: enough to part the books' tops, up to 30.
    private func maximumLean(shapes: [SIMD3<Float>], longest: CGFloat) -> Double {
        guard shapes.count > 1 else { return 4 }
        guard !showsCovers else { return min(14, 6 * Double(shapes.count - 1)) }
        // The spines' tops, side by side, with a little air between them.
        let tops = shapes.reduce(0) { $0 + CGFloat($1.z) } / longest * 1.05
        let parting = Double(min(1, max(0, tops / 2 - footSpread)))
        return min(30, max(8, Foundation.asin(parting) * 180 / .pi))
    }

    /// A book standing upright: its cover facing the viewer, or its spine, lettered top to
    /// bottom.
    @ViewBuilder
    private func standing(_ book: CloudBook, length: CGFloat, thickness: CGFloat, jitter: Double)
        -> some View
    {
        if showsCovers {
            ShareCover(
                book: book, look: input.look(for: book), cover: input.covers[book.id],
                style: .threeD, height: length, yaw: 0.16 + jitter * 0.14, pitch: -0.16
            )
            .grayscale(1)
            .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
            .frame(height: length, alignment: .bottom)
        } else {
            SpineView(book: book, look: input.look(for: book))
                .frame(width: length, height: thickness)
                .rotationEffect(.degrees(90))
                .frame(width: thickness, height: length)
                .grayscale(1)
                .shadow(color: .black.opacity(0.45), radius: 8, y: 4)
        }
    }
}

/// A round, tapered wastebasket of open wire mesh, seen from a little above, drawn in
/// two layers around whatever stands in it.
struct Wastebasket {
    /// The basket's middle, in the card's x coordinates.
    let center: CGFloat
    /// The y of the front of its base.
    let bottom: CGFloat
    /// The rim's radius.
    let radius: CGFloat
    /// The height from base to rim.
    let depth: CGFloat

    /// How flat the rim and base ellipses look: the camera's view down onto them.
    private let tilt: CGFloat = 0.2
    /// The base's radius as a share of the rim's.
    private let taper: CGFloat = 0.8

    private var top: CGFloat { bottom - depth }
    private var bottomRadius: CGFloat { radius * taper }

    /// A point on the wall at `angle` around (0 at the front) and `level` down from the rim
    /// (0...1).
    private func point(_ angle: CGFloat, _ level: CGFloat) -> CGPoint {
        let r = radius + (bottomRadius - radius) * level
        return CGPoint(
            x: center + r * sin(angle), y: top + depth * level + r * tilt * cos(angle))
    }

    private func ellipse(level: CGFloat) -> Path {
        let r = radius + (bottomRadius - radius) * level
        let y = top + depth * level
        return Path(
            ellipseIn: CGRect(x: center - r, y: y - r * tilt, width: r * 2, height: r * tilt * 2))
    }

    /// The front of the wall: from the front half of the rim down to the front half of the
    /// base.
    private var frontWall: Path {
        var path = Path()
        let steps = 48
        for step in 0...steps {
            let angle = -CGFloat.pi / 2 + CGFloat.pi * CGFloat(step) / CGFloat(steps)
            let p = point(angle, 0)
            if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        for step in (0...steps).reversed() {
            path.addLine(
                to: point(-CGFloat.pi / 2 + CGFloat.pi * CGFloat(step) / CGFloat(steps), 1))
        }
        path.closeSubpath()
        return path
    }

    /// Everything above the rim, and the basket's inside below it: where the books show.
    func interior(width: CGFloat) -> Path {
        Path(CGRect(x: 0, y: -10_000, width: width, height: 10_000 + top))
            .union(ellipse(level: 0)).union(frontWall)
    }

    /// The wires on the front or back half of the wall: two sets of diagonals that cross in
    /// open diamonds, and a ring halfway down.
    private func wires(front: Bool) -> Path {
        var path = Path()
        func trace(_ point: (CGFloat) -> (angle: CGFloat, level: CGFloat)) {
            var isDrawing = false
            for step in 0...32 {
                let (angle, level) = point(CGFloat(step) / 32)
                let p = self.point(angle, level)
                guard (cos(angle) >= 0) == front else {
                    isDrawing = false
                    continue
                }
                if isDrawing { path.addLine(to: p) } else { path.move(to: p) }
                isDrawing = true
            }
        }
        let count = 18
        let cell = 2 * CGFloat.pi / CGFloat(count)
        for index in 0..<count {
            for turn: CGFloat in [-1, 1] {
                let start = cell * CGFloat(index)
                trace { (start + turn * $0 * cell * 2.2, $0) }
            }
        }
        trace { (2 * .pi * $0, 0.5) }
        return path
    }

    /// The brushed metal of the wires, rim, and base, brightest a little left of the middle,
    /// where the light falls.
    private var metal: GraphicsContext.Shading {
        .linearGradient(
            Gradient(stops: [
                .init(color: Color(white: 0.30), location: 0),
                .init(color: Color(white: 0.62), location: 0.22),
                .init(color: Color(white: 0.82), location: 0.38),
                .init(color: Color(white: 0.58), location: 0.62),
                .init(color: Color(white: 0.34), location: 0.88),
                .init(color: Color(white: 0.24), location: 1),
            ]),
            startPoint: CGPoint(x: center - radius, y: 0),
            endPoint: CGPoint(x: center + radius, y: 0))
    }

    /// The floor shadow, the base plate, the back wall's wires, and the back of the rim,
    /// which the books stand in front of.
    func drawBack(in context: inout GraphicsContext) {
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: radius * 0.08))
            let shadow = CGRect(
                x: center - bottomRadius * 1.25, y: bottom - bottomRadius * tilt * 0.6,
                width: bottomRadius * 2.5, height: bottomRadius * tilt * 2.4)
            layer.fill(Path(ellipseIn: shadow), with: .color(.black.opacity(0.45)))
        }
        context.fill(ellipse(level: 1), with: .color(Color(white: 0.22)))
        context.stroke(
            wires(front: false), with: .color(Color(white: 0.38)),
            style: StrokeStyle(lineWidth: radius * 0.011, lineCap: .round))
        var back = Path()
        for step in 0...48 {
            let angle = CGFloat.pi / 2 + CGFloat.pi * CGFloat(step) / 48
            let p = point(angle, 0)
            if step == 0 { back.move(to: p) } else { back.addLine(to: p) }
        }
        context.stroke(back, with: .color(Color(white: 0.5)), lineWidth: radius * 0.035)
    }

    /// The front wall's wires and the front of the rim and base.
    func drawFront(in context: inout GraphicsContext) {
        let metal = metal
        // A dark edge under each wire keeps it visible over light covers.
        context.stroke(
            wires(front: true), with: .color(.black.opacity(0.45)),
            style: StrokeStyle(lineWidth: radius * 0.026, lineCap: .round))
        context.stroke(
            wires(front: true), with: metal,
            style: StrokeStyle(lineWidth: radius * 0.016, lineCap: .round))
        var rim = Path()
        var base = Path()
        for step in 0...48 {
            let angle = -CGFloat.pi / 2 + CGFloat.pi * CGFloat(step) / 48
            if step == 0 {
                rim.move(to: point(angle, 0))
                base.move(to: point(angle, 1))
            } else {
                rim.addLine(to: point(angle, 0))
                base.addLine(to: point(angle, 1))
            }
        }
        context.stroke(rim, with: metal, lineWidth: radius * 0.045)
        context.stroke(
            rim, with: .color(.white.opacity(0.35)),
            style: StrokeStyle(lineWidth: radius * 0.012))
        context.stroke(base, with: metal, lineWidth: radius * 0.05)
    }
}
