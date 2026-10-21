import XCTest

@testable import Bookworms

/// Checks how Checkout Card spreads a time frame's books over cards, and that each card draws.
final class CheckoutCardTests: XCTestCase {
    /// `count` fictional books finished in 2025, in finish order.
    private static func books(_ count: Int) -> [CloudBook] {
        (0..<count)
            .map { index in
                CloudBook(
                    id: index + 1,
                    title: index == 2
                        ? "An Unusually Long Fictional Title That Keeps Going: With a Subtitle"
                        : "Fictional Book \(index + 1)",
                    author: "Author \(index + 1)", coverURL: nil, detailCoverURL: nil,
                    finished: String(format: "2025-%02d-%02d", index / 28 % 12 + 1, index % 28 + 1))
            }
    }

    private func layout(_ count: Int, _ aspect: ShareAspect, username: String? = nil)
        -> CheckoutCardLayout
    {
        CheckoutCardLayout(
            ShareInput(
                template: .checkoutCard, aspect: aspect, books: Self.books(count),
                username: username))
    }

    /// A card fills the height inside the margins, 1520 pixels on a Story with its reach, 1174
    /// on Portrait, and 928 on Square, less 40 pixels of padding and the 2.7 rules of its
    /// heading, column headings, and footer.
    func testRowsPerCardFollowTheSize() {
        XCTAssertEqual(layout(5, .story), CheckoutCardLayout(count: 5, height: 1520))
        for (aspect, rows) in [(ShareAspect.story, 17), (.portrait, 13), (.square, 9)] {
            let layout = layout(5, aspect)
            XCTAssertEqual(layout.rule, CheckoutCardLayout.largestRule, "\(aspect)")
            XCTAssertEqual(layout.rowsPerCard, rows, "\(aspect)")
            XCTAssertEqual(layout.cards, [0..<5], "\(aspect)")
        }
    }

    /// The profile link takes 80 of a Story's 100 pixels of reach, and a line with them, at
    /// the widest and the closest rules.
    func testProfileLinkShortensAStoryCard() {
        XCTAssertEqual(layout(5, .story, username: "fictional").rowsPerCard, 16)
        XCTAssertEqual(layout(267, .story, username: "fictional").rowsPerCard, 21)
        XCTAssertEqual(layout(44, .story).rowsPerCard, 22)
        XCTAssertEqual(layout(5, .portrait, username: "fictional").rowsPerCard, 13)
    }

    /// A few more books than a card holds at the widest spacing close the rules up instead of
    /// starting a card for them.
    func testCloserRulesSaveACard() {
        let layout = layout(18, .story)
        XCTAssertEqual(layout.rule, 70)
        XCTAssertEqual(layout.rowsPerCard, 18)
        XCTAssertEqual(layout.cards, [0..<18])
    }

    /// A frame that needs more cards fills each card in finish order before the next, takes as
    /// few cards as the closest rules allow, and spaces the rules as widely as that number of
    /// cards allows.
    func testLongFramesContinueOnMoreCards() {
        XCTAssertEqual(layout(39, .story).rule, 64)
        XCTAssertEqual(layout(39, .story).cards, [0..<20, 20..<39])
        XCTAssertEqual(layout(267, .story).rule, 62)
        XCTAssertEqual(layout(267, .story).cards.count, 13)
        let linked = layout(267, .story, username: "fictional")
        XCTAssertEqual(linked.rule, CheckoutCardLayout.smallestRule)
        XCTAssertEqual(linked.cards.count, 13)
        for aspect in ShareAspect.allCases {
            for count in [1, 12, 39, 100, 267] {
                let label = "\(count) books on \(aspect)"
                let layout = layout(count, aspect)
                XCTAssertEqual(layout.cards.first?.lowerBound, 0, label)
                XCTAssertEqual(layout.cards.last?.upperBound, count, label)
                for (card, next) in zip(layout.cards, layout.cards.dropFirst()) {
                    XCTAssertEqual(card.upperBound, next.lowerBound, label)
                    XCTAssertEqual(card.count, layout.rowsPerCard, "\(label): a card isn't full")
                }
                XCTAssertLessThanOrEqual(layout.cards.last?.count ?? 0, layout.rowsPerCard, label)
                XCTAssertGreaterThanOrEqual(layout.rule, CheckoutCardLayout.smallestRule, label)
                XCTAssertLessThanOrEqual(layout.rule, CheckoutCardLayout.largestRule, label)
                let insets = ShareInput(template: .checkoutCard, aspect: aspect, books: [])
                    .reachingInsets
                let height = aspect.size.height - insets.top - insets.bottom
                func cards(_ rule: CGFloat) -> Int {
                    let rows = Int(
                        (height - 2 * CheckoutCardLayout.verticalPadding) / rule
                            - CheckoutCardLayout.reservedRules)
                    return (count + rows - 1) / rows
                }
                XCTAssertEqual(layout.cards.count, cards(CheckoutCardLayout.smallestRule), label)
                // Rules 2 pixels further apart would take another card.
                if layout.rule < CheckoutCardLayout.largestRule {
                    XCTAssertGreaterThan(
                        cards(layout.rule + 2), layout.cards.count, "\(label): rules too close")
                }
            }
        }
    }

    func testNoBooksTakeNoCards() {
        XCTAssertEqual(layout(0, .story).cards, [])
        XCTAssertEqual(layout(0, .story).books(on: 0, of: []), [])
    }

    /// Each card holds its own books, which the share text links, and a card past the last
    /// holds the last card's.
    func testEachCardHoldsItsOwnBooks() {
        let books = Self.books(39)
        let layout = layout(39, .story)
        XCTAssertEqual(layout.books(on: 0, of: books).map(\.id), Array(1...20))
        XCTAssertEqual(layout.books(on: 1, of: books).map(\.id), Array(21...39))
        XCTAssertEqual(layout.books(on: 9, of: books), layout.books(on: 1, of: books))
        XCTAssertEqual(layout.index(of: 9), 1)
    }

    /// The heading writes the reader's name, else their username, and prints "Reading record"
    /// alone without a profile. A name too long for the line still draws.
    @MainActor
    func testHeadingWritesTheReadersName() throws {
        func render(_ owner: ReaderProfile?) throws -> Data {
            var input = ShareInput(
                template: .checkoutCard, aspect: .portrait, books: Self.books(3),
                frame: .year(2025))
            input.owner = owner
            return try XCTUnwrap(input.render()?.cgImage?.dataProvider?.data as Data?)
        }
        let unnamed = try render(nil)
        let named = try render(ReaderProfile(id: 7, username: "averyreads", name: "Avery Quill"))
        let username = try render(ReaderProfile(id: 7, username: "averyreads"))
        let long = try render(
            ReaderProfile(
                id: 7, username: "averyreads",
                name: "Avery Bartholomew Quillingsworth-Montgomery the Third"))
        XCTAssertEqual(Set([unnamed, named, username, long]).count, 4)
    }

    /// Each card draws its own books at the image's size, and a card past the last draws the
    /// last.
    @MainActor
    func testEachCardRenders() throws {
        let books = Self.books(39)
        func render(card: Int, aspect: ShareAspect = .story) throws -> Data {
            let input = ShareInput(
                template: .checkoutCard, aspect: aspect, books: books, frame: .year(2025),
                card: card)
            let image = try XCTUnwrap(input.render()?.cgImage, "card \(card)")
            XCTAssertEqual(image.width, Int(aspect.size.width), "card \(card)")
            XCTAssertEqual(image.height, Int(aspect.size.height), "card \(card)")
            return try XCTUnwrap(image.dataProvider?.data as Data?)
        }
        let first = try render(card: 0)
        let last = try render(card: 1)
        XCTAssertNotEqual(first, last)
        XCTAssertEqual(try render(card: 9), last)
        for aspect in [ShareAspect.portrait, .square] {
            XCTAssertNotEqual(
                try render(card: 0, aspect: aspect), try render(card: 3, aspect: aspect))
        }
    }
}
