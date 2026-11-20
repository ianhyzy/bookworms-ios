import Foundation

/// How Seesaw weighs two readers' books for a time frame, and which way the plank tips.
///
/// Each side weighs its books' pages, as the 3D books' masses do (`BookShape`): a book without a
/// page count counts as `unknownPages`. The plank rocks on a curved base, so it settles where its
/// contact with the desk lies under the books' combined weight: the more one side outweighs the
/// other, the further it tips, until its end rests on the desk (`maximumTilt`).
struct SeesawBalance: Equatable {
    /// One reader's end of the plank.
    struct Side: Equatable {
        /// The books finished in the time frame, newest first.
        let books: [CloudBook]
        /// The pages the side weighs.
        let pages: Int

        init(books: [CloudBook]) {
            self.books = books
            pages = books.reduce(0) { $0 + ($1.pages ?? SeesawBalance.unknownPages) }
        }

        /// The books the plank shows, at most `limit`: the most popular first, by Hardcover
        /// ratings count, then the newest.
        func shown(limit: Int) -> [CloudBook] {
            Array(
                books.enumerated()
                    .sorted { ($0.element.ratingsCount ?? 0, -$0.offset) > ($1.element.ratingsCount ?? 0, -$1.offset) }
                    .prefix(limit)
                    .map(\.element))
        }
    }

    /// Which end the plank tips toward.
    enum Lean: Equatable {
        case mine, theirs, level
    }

    /// The page count of a book without one, as `BookShape` sizes it.
    static let unknownPages = 320

    let mine: Side
    let theirs: Side

    init(mine: [CloudBook], theirs: [CloudBook]) {
        self.mine = Side(books: mine)
        self.theirs = Side(books: theirs)
    }

    /// Weighs the books each library finished in `frame`, newest first, as the Desk lists them.
    init(frame: TimeFrame, mine: [CloudBook], theirs: [CloudBook]) {
        self.init(
            mine: ShareTemplate.pile.books(from: mine, in: frame),
            theirs: ShareTemplate.pile.books(from: theirs, in: frame))
    }

    var lean: Lean {
        mine.pages == theirs.pages ? .level : mine.pages > theirs.pages ? .mine : .theirs
    }

    /// The plank's turn, in radians, from level toward the heavier side, at most `maximum`.
    ///
    /// The plank's own weight, `plankPages`, steadies it, so a few pages' difference tips it a
    /// little. The base's curve turns a side's share of the weight into a turn: the contact
    /// moves `radius × angle` along the desk, under the books' center of weight, which lies
    /// `arm × difference / total` from the middle.
    func tilt(arm: Float, radius: Float, plankPages: Int, maximum: Float) -> Float {
        let difference = Float(abs(mine.pages - theirs.pages))
        let total = Float(mine.pages + theirs.pages + plankPages)
        guard difference > 0, total > 0 else { return 0 }
        return min(maximum, arm * difference / total / radius)
    }
}
