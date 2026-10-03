/// "Whose photos" filter, generic over the uploader key.
///
/// Items without a key (legacy photos uploaded before trips existed) are grouped as
/// `.unknown`. The filter is only worth showing when there's more than one group, so a
/// single-person trip, or a list made only of legacy photos, shows no filter at all.
struct UploaderFilter<Key: Hashable & Comparable & Sendable>: Equatable, Sendable {
    enum Option: Hashable, Sendable {
        case uploader(Key)
        case unknown
    }

    /// Options to hide. Empty means everyone is shown; storing the hidden set (not the shown
    /// one) means a new uploader joining the trip is visible by default.
    var hidden: Set<Option> = []

    /// Options present in `items`, uploaders sorted by key, `.unknown` last.
    static func options<Item>(in items: [Item], key: (Item) -> Key?) -> [Option] {
        var keys = Set<Key>(), hasUnknown = false
        for item in items {
            if let k = key(item) { keys.insert(k) } else { hasUnknown = true }
        }
        return keys.sorted().map(Option.uploader) + (hasUnknown ? [.unknown] : [])
    }

    static func isUseful<Item>(for items: [Item], key: (Item) -> Key?) -> Bool {
        options(in: items, key: key).count > 1
    }

    func isShown(_ option: Option) -> Bool { !hidden.contains(option) }

    func includes<Item>(_ item: Item, key: (Item) -> Key?) -> Bool {
        isShown(key(item).map(Option.uploader) ?? .unknown)
    }

    func apply<Item>(to items: [Item], key: (Item) -> Key?) -> [Item] {
        hidden.isEmpty ? items : items.filter { includes($0, key: key) }
    }

    /// Toggle one option, never leaving every option hidden.
    mutating func toggle(_ option: Option, among options: [Option]) {
        if hidden.contains(option) {
            hidden.remove(option)
        } else if options.filter(isShown).count > 1 {
            hidden.insert(option)
        }
    }

    /// Show only `option`.
    mutating func showOnly(_ option: Option, among options: [Option]) {
        hidden = Set(options).subtracting([option])
    }

    /// Drop hidden options that no longer exist, so stale state can't hide new data.
    mutating func prune(to options: [Option]) {
        hidden.formIntersection(options)
        if !options.isEmpty, hidden.count >= options.count { hidden = [] }
    }
}
