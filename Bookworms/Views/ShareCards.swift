import SwiftUI

/// One book, as a 3D book or a flat cover on a backdrop in its spine's color family, with its
/// details: the finish date, rating, and length for Just Finished, or the progress and start
/// date for Currently Reading.
struct FeaturedBookCard: View {
    let input: ShareInput

    var body: some View {
        if let book = input.books.first {
            card(book, look: input.look(for: book))
        }
    }

    private func card(_ book: CloudBook, look: SpineLook) -> some View {
        let aspect = input.aspect
        let isSquare = aspect == .square
        let theme = input.theme
        let edge = theme.backdropDark.color
        return ZStack {
            // A glow behind the book that fades to the dark field.
            RadialGradient(
                stops: [
                    .init(color: theme.glow.color, location: 0),
                    .init(color: theme.backdropLight.color, location: 0.4),
                    .init(color: edge, location: 1),
                ],
                center: isSquare ? UnitPoint(x: 0.27, y: 0.5) : UnitPoint(x: 0.5, y: 0.34),
                startRadius: 0, endRadius: aspect.size.width * 0.9)
            // A long, eased scrim settles the glow into the field behind the text without a
            // visible edge.
            LinearGradient(
                stops: [
                    .init(color: edge.opacity(0), location: isSquare ? 0.32 : 0.42),
                    .init(color: edge.opacity(0.6), location: isSquare ? 0.48 : 0.56),
                    .init(color: edge, location: isSquare ? 0.62 : 0.7),
                ],
                startPoint: isSquare ? .leading : .top, endPoint: isSquare ? .trailing : .bottom)
            Group {
                if isSquare {
                    HStack(spacing: 40) {
                        hero(book, look: look).frame(width: 470)
                        details(book, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(spacing: 44) {
                        hero(book, look: look)
                        details(book, alignment: .center)
                    }
                }
            }
            .padding(aspect.insets)
        }
    }

    private func hero(_ book: CloudBook, look: SpineLook) -> some View {
        let cover = input.covers[book.id]
        let ratio = ShareCover.aspect(of: cover, style: input.coverStyle)
        return GeometryReader { proxy in
            ShareCover(
                book: book, look: look, cover: cover, style: input.coverStyle,
                height: min(proxy.size.height * 0.88, proxy.size.width * 0.86 / ratio),
                yaw: 0.6 + (ShareStyle.unit(input.seed, book.id, 4) - 0.5) * 0.12,
                pitch: -0.1 + (ShareStyle.unit(input.seed, book.id, 5) - 0.5) * 0.06
            )
            .shadow(color: .black.opacity(0.5), radius: 36, y: 28)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func details(_ book: CloudBook, alignment: HorizontalAlignment) -> some View {
        let isSquare = input.aspect == .square
        let isReading = input.template == .currentlyReading
        let label = isReading ? "Currently reading" : book.finishedDate != nil ? "Finished" : nil
        let details = ShareStyle.details(book, isReading: isReading)
        return VStack(alignment: alignment, spacing: 18) {
            if let label {
                ShareStyle.label(label).foregroundStyle(ShareStyle.gold)
            }
            ShareFittingText(
                forms: ShareStyle.titles(book), size: isSquare ? 64 : 80, minimumScale: 0.5,
                lines: isSquare ? 4 : 3, book: book
            ) {
                ShareStyle.serif($0, .semibold)
            }
            Text(SpineView.shortAuthor(book.author))
                .font(ShareStyle.serif(40))
                .lineLimit(2)
                .minimumScaleFactor(0.75)
            if isReading {
                if let progress = book.progress {
                    progressBar(progress, width: isSquare ? 250 : 440)
                }
            } else if input.showsRatings, let rating = book.rating, rating > 0 {
                ShareStars(rating: rating, size: 44)
            }
            if !details.isEmpty {
                Text(details)
                    .font(.system(size: 32))
                    .opacity(0.75)
                    .lineLimit(2)
            }
        }
        .multilineTextAlignment(alignment == .center ? .center : .leading)
        .foregroundStyle(ShareStyle.cream.color)
        .layoutPriority(1)
    }

    /// A gold bar filled to `progress` (0...1), with the percentage beside it.
    private func progressBar(_ progress: Double, width: CGFloat) -> some View {
        let value = min(1, max(0, progress))
        return HStack(spacing: 20) {
            Capsule()
                .fill(ShareStyle.cream.color.opacity(0.2))
                .overlay(alignment: .leading) {
                    Capsule().fill(ShareStyle.gold).frame(width: max(18, width * value))
                }
                .frame(width: width, height: 18)
            Text(value.formatted(.percent.precision(.fractionLength(0))))
                .font(ShareStyle.serif(48, .semibold))
                .foregroundStyle(ShareStyle.gold)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}

/// The year's highest-rated books fanned like a hand of cards, with a ranked list.
struct TopFiveCard: View {
    let input: ShareInput

    /// Fan positions by rank: the first in the middle, then alternating outward.
    private static let slots: [CGFloat] = [0, -1, 1, -2, 2]

    var body: some View {
        let aspect = input.aspect
        let books = input.books
        let theme = input.theme
        ZStack {
            LinearGradient(
                colors: [theme.backdropLight.color, theme.backdropDark.color],
                startPoint: .top, endPoint: .bottom)
            // A glow behind the fan.
            RadialGradient(
                colors: [theme.glow.color, .clear], center: UnitPoint(x: 0.5, y: 0.42),
                startRadius: 0, endRadius: aspect.size.width * 0.75)
            VStack(spacing: aspect == .story ? 48 : 32) {
                Text(heading)
                    .font(ShareStyle.serif(aspect == .story ? 84 : 68, .semibold))
                    .foregroundStyle(ShareStyle.cream.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                fan(books)
                VStack(spacing: aspect == .story ? 22 : 14) {
                    ForEach(Array(books.enumerated()), id: \.element.id) { index, book in
                        row(rank: index + 1, book: book, showsAuthor: aspect != .square)
                    }
                }
                .layoutPriority(1)
            }
            .padding(aspect.insets)
        }
    }

    /// "My top 5 of 2025", "My top book of August 2025", or "My all-time top 5".
    private var heading: String {
        let top = input.books.count == 1 ? "top book" : "top \(input.books.count)"
        return input.frame == .lifetime ? "My all-time \(top)" : "My \(top) of \(input.period)"
    }

    private func fan(_ books: [CloudBook]) -> some View {
        // Centers the fan when fewer than five books leave it lopsided.
        let used = Self.slots.prefix(books.count)
        let middle = used.reduce(0, +) / CGFloat(max(1, used.count))
        return GeometryReader { proxy in
            let size = proxy.size
            // A lone book takes the fan's space, sized as a featured book's hero is.
            let leadHeight =
                books.count == 1
                ? min(
                    size.height * 0.88,
                    size.width * 0.86
                        / ShareCover.aspect(of: input.covers[books[0].id], style: input.coverStyle))
                : min(size.height * 0.78, size.width * 0.55)
            // An outer book, at 0.82 of the lead height and turned about 15 degrees, reaches up
            // to 0.47 lead heights from its center with the widest 3D book, or 0.5 with the
            // widest flat cover (`ShareCover.aspect`). This spacing keeps the outermost slot (2)
            // inside the fan's width, and so in the gutters.
            let reach = input.coverStyle == .flat ? 0.5 : 0.47
            let spacing = min(size.width * 0.16, (size.width / 2 - reach * leadHeight) / 2)
            // Each book's slot, height, turn in degrees, and drop below the fan's middle: outer
            // books sit lower and turn further, as a hand of cards curves.
            let cards = books.enumerated()
                .map { index, book in
                    let slot = Self.slots[index] - middle
                    let jitter = ShareStyle.unit(input.seed, book.id, 6) - 0.5
                    return (
                        slot: slot, jitter: jitter, height: leadHeight * (index == 0 ? 1 : 0.82),
                        turn: Double(slot) * 7 + jitter * 2,
                        drop: slot * slot * 14 + (index == 0 ? 0 : leadHeight * 0.06)
                    )
                }
            // The drops push the fan's lowest corners down, so the fan rises by half the
            // difference between the turned books' reach below and above the middle. That leaves
            // as much room under the books, above the ranked list, as over them.
            let reaches = zip(books, cards)
                .map { book, card in
                    let width =
                        card.height
                        * ShareCover.aspect(of: input.covers[book.id], style: input.coverStyle)
                    let turn = abs(card.turn) * .pi / 180
                    let half = (width * sin(turn) + card.height * cos(turn)) / 2
                    return (above: half - card.drop, below: half + card.drop)
                }
            let lift =
                ((reaches.map(\.below).max() ?? 0) - (reaches.map(\.above).max() ?? 0)) / 2
            ZStack {
                // The first-ranked book is drawn last, in front.
                ForEach(Array(books.enumerated().reversed()), id: \.element.id) { index, book in
                    let card = cards[index]
                    ShareCover(
                        book: book, look: input.look(for: book), cover: input.covers[book.id],
                        style: input.coverStyle, height: card.height,
                        yaw: 0.36 + card.jitter * 0.12, pitch: -0.1
                    )
                    .shadow(color: .black.opacity(0.45), radius: 24, y: 18)
                    .rotationEffect(.degrees(card.turn))
                    .position(
                        x: size.width / 2 + card.slot * spacing,
                        y: size.height / 2 + card.drop - lift)
                }
            }
        }
    }

    /// A ranked book: its rank, title, author, and stars. The title letters at 40 pixels or
    /// more, wrapping to a second line before it shrinks, so it stays legible on a phone.
    private func row(rank: Int, book: CloudBook, showsAuthor: Bool) -> some View {
        // The rank and stars line up with the title's first line when it wraps.
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(String(rank))
                .font(ShareStyle.serif(46, .bold))
                .foregroundStyle(ShareStyle.gold)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 0) {
                ShareFittingText(
                    forms: ShareStyle.titles(book), size: 44, minimumScale: 40 / 44, lines: 2,
                    book: book
                ) {
                    ShareStyle.serif($0, .semibold)
                }
                if showsAuthor {
                    Text(SpineView.shortAuthor(book.author))
                        .font(ShareStyle.serif(32))
                        .opacity(0.7)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 16)
            if input.showsRatings, let rating = book.rating, rating > 0 {
                ShareStars(rating: rating, size: 30)
            }
        }
        .foregroundStyle(ShareStyle.cream.color)
    }
}
