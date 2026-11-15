import Foundation

/// The books the reader pinned to Top Five, in the order pinned, saved in this device's user
/// defaults under `key` so views show a change at once.
///
/// The pins sync through iCloud as the account's `TopFivePinsV1` record, so the iPhone and the
/// Mac pin the same books (`AppModel.syncTopFivePins()`); they never reach Hardcover. They hold
/// Hardcover book IDs, which survive a library sync; a pinned book missing from the library is
/// ignored.
struct TopFivePins: RawRepresentable, Equatable {
    static let key = "TopFivePins"
    /// The user defaults key of the pins as iCloud last confirmed them, a `TopFivePinsV1` in JSON,
    /// which tells a change on this device from one on another.
    static let syncedKey = "TopFivePinsSynced"
    /// The user defaults key of the account whose pins these are, which a pin that iCloud never
    /// confirmed can't tell by itself.
    static let accountKey = "TopFivePinsAccount"
    /// The most books a reader can pin: Top Five's whole list.
    static let limit = 5

    private(set) var ids: [Int] = []

    init() {}

    init(ids: [Int]) {
        self.init(rawValue: ids.map(String.init).joined(separator: ","))
    }

    /// Reads IDs separated by commas, such as "12,34", keeping the first `limit` valid ones.
    init(rawValue: String) {
        var ids: [Int] = []
        for id in rawValue.split(separator: ",").compactMap({ Int($0) })
        where ids.count < Self.limit && !ids.contains(id) {
            ids.append(id)
        }
        self.ids = ids
    }

    var rawValue: String { ids.map(String.init).joined(separator: ",") }

    var isFull: Bool { ids.count >= Self.limit }

    func contains(_ id: Int) -> Bool { ids.contains(id) }

    /// Unpins every book whose ID is not in `ids`.
    mutating func keep(only ids: Set<Int>) {
        self.ids.removeAll { !ids.contains($0) }
    }

    /// Unpins `id` when it is pinned, else pins it last. Does nothing to an unpinned book while
    /// the pins are full.
    mutating func toggle(_ id: Int) {
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
        } else if !isFull {
            ids.append(id)
        }
    }
}
