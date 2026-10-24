import SwiftUI

/// How Checkout Card spreads a time frame's books over cards: the spacing of the cards' rules,
/// and which books each card holds, filled in order, as a librarian fills one card before
/// starting the next.
///
/// A card fills the space inside the image's margins (`ShareInput.reachingInsets`). Its heading
/// takes `headingRules`, its column headings `columnHeadingRules`, and its footer one rule;
/// every other rule holds one book. The rules are `largestRule` apart when the books fit on as
/// few cards that way as at `smallestRule`, and otherwise as far apart as that fewest number of
/// cards allows, in 2-pixel steps. Handwriting letters at a fixed share of the rule
/// (`CheckoutCard.handScale`), so `smallestRule` sets the smallest handwriting.
struct CheckoutCardLayout: Equatable {
    static let largestRule: CGFloat = 72
    static let smallestRule: CGFloat = 58
    /// The heading's height, in rules.
    static let headingRules: CGFloat = 1.1
    /// The column headings' height, in rules.
    static let columnHeadingRules: CGFloat = 0.6
    /// The rules that the heading, the column headings, and the footer take.
    static let reservedRules = headingRules + columnHeadingRules + 1
    /// The room above the heading and below the footer, in pixels.
    static let verticalPadding: CGFloat = 20

    /// The rules' spacing, in pixels.
    let rule: CGFloat
    /// The books one card holds.
    let rowsPerCard: Int
    /// Each card's books, as a range of indexes into the books in order. Empty without books.
    let cards: [Range<Int>]

    /// Lays out `count` books on cards `height` pixels tall.
    init(count: Int, height: CGFloat) {
        func rows(_ rule: CGFloat) -> Int {
            max(1, Int((height - 2 * Self.verticalPadding) / rule - Self.reservedRules))
        }
        func cardCount(_ rule: CGFloat) -> Int { (count + rows(rule) - 1) / rows(rule) }
        let fewest = cardCount(Self.smallestRule)
        rule =
            stride(from: Self.largestRule, through: Self.smallestRule, by: -2)
            .first { cardCount($0) == fewest } ?? Self.smallestRule
        let rowsPerCard = rows(rule)
        self.rowsPerCard = rowsPerCard
        cards = stride(from: 0, to: count, by: rowsPerCard)
            .map {
                $0..<min($0 + rowsPerCard, count)
            }
    }

    /// Lays out `input`'s books on cards that fill the space inside its margins.
    init(_ input: ShareInput) {
        let insets = input.reachingInsets
        self.init(
            count: input.books.count,
            height: input.aspect.size.height - insets.top - insets.bottom)
    }

    /// The index of card `card`, or of the last card when there are fewer.
    func index(of card: Int) -> Int { min(max(card, 0), max(cards.count - 1, 0)) }

    /// The books of `books`, laid out in order, that card `card` holds (`index(of:)`).
    func books(on card: Int, of books: [CloudBook]) -> [CloudBook] {
        cards.isEmpty ? [] : Array(books[cards[index(of: card)]])
    }
}

/// The checkout card from a library book's pocket, filled in with a time frame's books: aged
/// card stock lying on the desk, with a heading filled in as a form is, such as "Avery Quill's
/// reading record — 2025" with the name and the frame written by hand, and ruled columns, each
/// book's finish date stamped in violet ink and its title written by hand, oldest first. It
/// uses the stock, inks, stamp, and red heading rule of the date-due card on a book's
/// **Your reading** (`Stationery`).
///
/// A frame with more books than a card holds continues on more cards (`CheckoutCardLayout`).
/// The image draws the card that `ShareInput.card` names, and its footer numbers it, such as
/// "Card 2 of 3". Each entry varies a little, by its book, in where it starts, its slant, its
/// baseline, and its ink, as handwriting and stamping do. A title takes its longest form that
/// fits its line at a size down to `smallestHand` (`ShareFittingText`), so every title stays on
/// its own rule.
struct CheckoutCard: View {
    /// The Google Fonts family that the handwriting uses: Caveat, a casual hand under the SIL
    /// Open Font License, which `GoogleFonts` checks before it downloads a family.
    static let handFamily = "Caveat"
    static let handWeight = 500
    /// The handwriting's size as a share of the rule.
    static let handScale: CGFloat = 0.82
    /// The smallest handwriting, in pixels, to which a long title shrinks before it drops its
    /// subtitle: 85 percent of the handwriting at `CheckoutCardLayout.smallestRule`.
    static let smallestHand = CheckoutCardLayout.smallestRule * handScale * 0.85
    /// Noteworthy, which iOS and macOS install, for when Caveat can't download.
    private static let fallbackHand = SpineFonts.installedFace(named: "Noteworthy-Light")

    let input: ShareInput

    /// The handwriting at `size`: `face`, else Noteworthy, else the system serif in italics.
    static func hand(_ face: FontFace?, size: CGFloat) -> Font {
        (face ?? fallbackHand)?.font(size: size) ?? .system(size: size, design: .serif).italic()
    }

    var body: some View {
        let layout = CheckoutCardLayout(input)
        let index = layout.index(of: input.card)
        let books = layout.books(on: index, of: input.books)
        ZStack {
            ShareBlotter()
            card(
                books: books, layout: layout,
                number: layout.cards.count > 1 ? "Card \(index + 1) of \(layout.cards.count)" : nil
            )
            .padding(input.reachingInsets)
        }
    }

    private func card(books: [CloudBook], layout: CheckoutCardLayout, number: String?)
        -> some View
    {
        let rule = layout.rule
        let dateColumn = rule * 3.3
        return VStack(spacing: 0) {
            heading(rule: rule)
            VStack(spacing: 0) {
                columnHeadings(rule: rule, dateColumn: dateColumn)
                ForEach(0..<layout.rowsPerCard, id: \.self) { row in
                    entry(
                        row < books.count ? books[row] : nil, rule: rule, dateColumn: dateColumn)
                }
            }
            // The column's printed red rule, from the column headings to the last line.
            .overlay(alignment: .leading) {
                Rectangle().fill(Stationery.red).frame(width: 2)
                    .padding(.leading, Self.side + dateColumn)
            }
            Spacer(minLength: 0)
            Text(number ?? "")
                .font(.system(size: rule * 0.34, weight: .semibold).smallCaps())
                .tracking(1)
                .foregroundStyle(Stationery.labelInk)
                .frame(maxWidth: .infinity, minHeight: rule, alignment: .trailing)
                .padding(.horizontal, Self.side)
        }
        .padding(.vertical, CheckoutCardLayout.verticalPadding)
        .environment(\.bookTextGround, Stationery.stockValue)
        // Only the card casts the shadow, not each line of ink on it.
        .background { stock.shadow(color: .black.opacity(0.5), radius: 26, y: 16) }
    }

    /// The space between the card's edges and its text, in pixels.
    private static let side: CGFloat = 32

    /// Card stock that has yellowed toward its edges, with the dither that the app's paper props
    /// use (`CardStockSheet`).
    private var stock: some View {
        let shape = RoundedRectangle(cornerRadius: 14)
        return ZStack {
            Stationery.stock
            Image(.paperDither).resizable(resizingMode: .tile).opacity(0.06)
            EllipticalGradient(
                colors: [.clear, Color(red: 0.62, green: 0.45, blue: 0.22).opacity(0.26)],
                startRadiusFraction: 0.3, endRadiusFraction: 0.75)
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(.black.opacity(0.12), lineWidth: 1.5) }
    }

    /// The heading, one line of a form over the red rule: the reader's Hardcover name written
    /// before the printed "'s reading record —", then the time frame written after it. Without
    /// `ShareInput.owner`, it prints "Reading record —". A long name shrinks a little, then
    /// gives way to its first word, then ends with an ellipsis, so the frame always shows.
    private func heading(rule: CGFloat) -> some View {
        let size = rule * 0.88
        let printed = Font.system(size: rule * 0.42, weight: .medium)
        // One pen in one sitting, so the name and the frame share an ink; each sits a little
        // off level, as an entry does.
        let unit = { ShareStyle.unit(0, input.owner?.id ?? 0, $0) }
        let ink = Stationery.penInk.opacity(0.92 + 0.08 * unit(1))
        return HStack(alignment: .lastTextBaseline, spacing: 0) {
            if let owner = input.owner {
                let forms = [owner.displayName, owner.shortName]
                ShareFittingText(
                    forms: forms[0] == forms[1] ? [forms[0]] : forms, size: size, minimumScale: 0.8
                ) {
                    Self.hand(input.handwriting, size: $0)
                }
                .foregroundStyle(ink)
                .rotationEffect(.degrees((unit(2) - 0.5) * 2), anchor: .leading)
                .offset(y: (unit(3) - 0.5) * rule * 0.08)
                Text("’s reading record —").font(printed).fixedSize()
                    .padding(.leading, rule * 0.08)
            } else {
                Text("Reading record —").font(printed).fixedSize()
            }
            Text(input.period)
                .font(Self.hand(input.handwriting, size: size))
                .foregroundStyle(ink)
                .fixedSize()
                .rotationEffect(.degrees(-1.5 + (unit(4) - 0.5) * 1.6), anchor: .leading)
                .offset(y: (unit(5) - 0.5) * rule * 0.08)
                .padding(.leading, rule * (0.18 + 0.12 * unit(6)))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Stationery.labelInk)
        .padding(.horizontal, Self.side)
        // Writing sits on the line, as the entries' does.
        .padding(.bottom, rule * 0.16)
        .frame(height: rule * CheckoutCardLayout.headingRules, alignment: .bottom)
        .overlay(alignment: .bottom) { Rectangle().fill(Stationery.red).frame(height: 3) }
    }

    private func columnHeadings(rule: CGFloat, dateColumn: CGFloat) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 0) {
            Text("Finished").frame(width: dateColumn, alignment: .leading)
            Text("Title").padding(.leading, rule * 0.3)
            Spacer(minLength: 0)
        }
        .font(.system(size: rule * 0.36, weight: .semibold).smallCaps())
        .tracking(1)
        .foregroundStyle(Stationery.labelInk)
        .padding(.horizontal, Self.side)
        .padding(.bottom, rule * 0.18)
        .frame(height: rule * CheckoutCardLayout.columnHeadingRules, alignment: .bottom)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Stationery.inkValue.color.opacity(0.4)).frame(height: 3)
        }
    }

    /// One ruled line: the book's stamped finish date and its handwritten title, or a blank
    /// line without a book.
    private func entry(_ book: CloudBook?, rule: CGFloat, dateColumn: CGFloat) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 0) {
            if let book {
                let unit = { ShareStyle.unit(0, book.id, $0) }
                Text(book.finishedDate?.formatted(Stationery.stampFormat).uppercased() ?? "")
                    .font(.system(size: rule * 0.36, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    // An inked stamp sits a degree or two off level and inks a little unevenly.
                    .foregroundStyle(Stationery.stampInk.opacity(0.9 + 0.1 * unit(1)))
                    .rotationEffect(.degrees((unit(2) - 0.5) * 3.5))
                    .offset(x: (unit(3) - 0.5) * rule * 0.12)
                    .frame(width: dateColumn, alignment: .leading)
                // A different pen now and then, as the entries were written on different days.
                ShareFittingText(
                    forms: ShareStyle.titles(book), size: rule * Self.handScale,
                    minimumScale: Self.smallestHand / (rule * Self.handScale), book: book
                ) {
                    Self.hand(input.handwriting, size: $0)
                }
                .foregroundStyle(
                    (unit(4) < 0.25 ? Stationery.ink : Stationery.penInk)
                        .opacity(0.92 + 0.08 * unit(5))
                )
                .rotationEffect(.degrees((unit(6) - 0.5) * 1.6), anchor: .leading)
                .offset(y: (unit(7) - 0.5) * rule * 0.08)
                .padding(.leading, rule * (0.3 + 0.25 * unit(8)))
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, Self.side)
        // Writing sits on the line, so descenders cross it.
        .padding(.bottom, rule * 0.16)
        .frame(height: rule, alignment: .bottom)
        .overlay(alignment: .bottom) { Rectangle().fill(Stationery.rule).frame(height: 2) }
    }
}
