import SwiftUI

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// The Share tab's **Compare with** section: the reader the friends' templates compare with,
/// which opens `ShareReaderPicker`, and a link to that reader's Hardcover profile.
///
/// Without this iPhone's Hardcover sign-in, it offers **Connect Hardcover** instead. Its
/// footer reports a refresh in progress or the last failure.
struct ShareReaderSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    /// The reader the image compares with.
    let reader: SocialModel.Reader?
    /// The reader chosen in the picker.
    @Binding var selection: Int?
    @Binding var showsAccount: Bool

    var body: some View {
        let social = model.social
        Section {
            if model.canCompare {
                NavigationLink {
                    ShareReaderPicker(selection: $selection, shown: reader?.id)
                } label: {
                    if let reader {
                        ShareReaderLabel(
                            reader: reader, isLoading: social.loadingReaders.contains(reader.id))
                    } else {
                        Label("Choose someone", systemImage: "person.crop.circle.badge.plus")
                    }
                }
                if let reader, let url = reader.profile.profileURL {
                    Button {
                        openURL(url)
                    } label: {
                        Label(
                            "View @\(reader.profile.username) on Hardcover",
                            systemImage: "arrow.up.right.square")
                    }
                }
            } else {
                Button("Connect Hardcover", systemImage: "person.crop.circle.badge.plus") {
                    showsAccount = true
                }
            }
        } header: {
            Text("Compare with")
        } footer: {
            if !model.canCompare {
                Text("Connect Hardcover to compare ratings with the people you follow.")
            } else if social.isSyncing {
                Text("Updating the people you follow…")
            } else if let failure = social.failure {
                Text(failure)
            }
        }
    }
}

/// A reader's photo, name, username, and how their taste compares, as one VoiceOver element.
struct ShareReaderLabel: View {
    let reader: SocialModel.Reader
    var isLoading = false
    var isSelected = false

    var body: some View {
        HStack(spacing: 12) {
            ReaderAvatarView(profile: reader.profile, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(reader.profile.displayName)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if isLoading {
                ProgressView()
            } else if let score = reader.match?.score {
                Text("\(score)%")
                    .font(.title3.bold())
                    .foregroundStyle(.tint)
                    .accessibilityLabel("\(score) percent match")
            }
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Selected")
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "@robin · Kindred shelves", or what keeps the reader from a score.
    private var detail: String {
        let state: String =
            if isLoading {
                "Loading ratings"
            } else if reader.hasNoRatings {
                "No public ratings"
            } else if let match = reader.match {
                match.tier
                    ?? (match.shared.count == 1
                        ? "1 book in common" : "\(match.shared.count) books in common")
            } else {
                "Ratings not downloaded"
            }
        return "@\(reader.profile.username) · \(state)"
    }
}

/// A reader's Hardcover photo in a circle, or their initials without one. The photo loads
/// through `CoverStore`, with its HTTPS and size limits and its caches.
struct ReaderAvatarView: View {
    @Environment(AppModel.self) private var model
    let profile: ReaderProfile
    let size: CGFloat
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(.tint.opacity(0.2))
                    Text(ShareAvatar.initials(profile))
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(.tint)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
        .task(id: profile.avatarURL) {
            guard let url = profile.avatarURL else { return }
            image = await model.covers.image(at: [url], maximumPixelSize: Int(size * 3))
        }
    }
}

/// The readers to compare with, best match first: the people the account follows, then
/// public readers looked up by username, each with a link to their Hardcover profile.
///
/// The search field filters the list by name or username. A query that names no listed reader
/// offers to look up that username on Hardcover. Pulling down refreshes the list.
struct ShareReaderPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Binding var selection: Int?
    /// The reader the image compares with now.
    let shown: Int?
    @State private var query = ""
    @State private var isLookingUp = false
    @State private var lookupError: String?

    var body: some View {
        let readers = filtered
        let followed = readers.filter(\.isFollowed)
        let others = readers.filter { !$0.isFollowed }
        List {
            if let candidate {
                lookupSection(candidate)
            }
            if !followed.isEmpty {
                Section("Following") { ForEach(followed, content: row) }
            }
            if !others.isEmpty {
                Section("Looked up") { ForEach(others, content: row) }
            }
            if model.social.readers.isEmpty && query.isEmpty {
                ContentUnavailableView(
                    "No one to compare with yet", systemImage: "person.2",
                    description: Text(
                        model.social.isSyncing
                            ? "Loading the people you follow on Hardcover."
                            : "Follow readers on Hardcover, or search for a public username."))
            }
        }
        .searchable(text: $query, prompt: "Name or Hardcover username")
        .refreshable { await model.syncSocial(force: true) }
        .onChange(of: query) { lookupError = nil }
        .navigationTitle("Compare with")
    }

    private var filtered: [SocialModel.Reader] {
        guard !query.isEmpty else { return model.social.readers }
        return model.social.readers.filter {
            $0.profile.displayName.localizedStandardContains(query)
                || $0.profile.username.localizedStandardContains(query)
        }
    }

    /// The username the query names when no listed reader has it.
    private var candidate: String? {
        guard let username = ReaderProfile.username(from: query) else { return nil }
        let isListed = model.social.readers.contains {
            $0.profile.username.lowercased() == username.lowercased()
        }
        return isListed ? nil : username
    }

    @ViewBuilder
    private func lookupSection(_ username: String) -> some View {
        Section {
            if model.canLookUpReaders {
                Button {
                    Task { await lookUp(username) }
                } label: {
                    HStack {
                        Label("Compare with @\(username)", systemImage: "magnifyingglass")
                        Spacer()
                        if isLookingUp { ProgressView() }
                    }
                }
                .disabled(isLookingUp)
                if let lookupError {
                    Text(lookupError).foregroundStyle(.red)
                }
            } else {
                Text("Connect Hardcover to look up readers.")
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Any public Hardcover reader. Bookworms only reads their ratings.")
        }
    }

    private func row(_ reader: SocialModel.Reader) -> some View {
        HStack {
            Button {
                selection = reader.id
                Task { await model.downloadReader(reader.id) }
                dismiss()
            } label: {
                ShareReaderLabel(
                    reader: reader,
                    isLoading: model.social.loadingReaders.contains(reader.id),
                    isSelected: reader.id == shown
                )
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if let url = reader.profile.profileURL {
                Button {
                    openURL(url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .imageScale(.large)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("View @\(reader.profile.username) on Hardcover")
            }
        }
        .contextMenu {
            if let url = reader.profile.profileURL {
                Button("View on Hardcover", systemImage: "arrow.up.right.square") { openURL(url) }
            }
        }
    }

    private func lookUp(_ username: String) async {
        isLookingUp = true
        lookupError = nil
        defer { isLookingUp = false }
        do {
            let reader = try await model.lookUpReader(username)
            selection = reader.id
            query = ""
            dismiss()
        } catch is CancellationError {
        } catch {
            lookupError =
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
