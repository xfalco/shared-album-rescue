import Foundation

/// Resolves hashed contributor IDs to display names using the map Photos keeps at
/// scopes/cloudsharing/data/cloudSharedPersonInfos.plist. Entries are heterogeneous:
/// some carry fullName/firstName/lastName, some only emails or phones.
struct PersonDirectory {
    private let names: [String: String]

    init(library: URL) {
        let url = library.appendingPathComponent("scopes/cloudsharing/data/cloudSharedPersonInfos.plist")
        var mapping: [String: String] = [:]
        if let data = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for (key, value) in plist {
                guard let info = value as? [String: Any] else { continue }
                var candidates: [String] = []
                if let full = info["fullName"] as? String, !full.isEmpty { candidates.append(full) }
                let joined = [info["firstName"] as? String, info["lastName"] as? String]
                    .compactMap { $0 }.joined(separator: " ")
                if !joined.trimmingCharacters(in: .whitespaces).isEmpty { candidates.append(joined) }
                if let email = info["email"] as? String, !email.isEmpty { candidates.append(email) }
                if let email = (info["emails"] as? [String])?.first { candidates.append(email) }
                if let phone = (info["phones"] as? [String])?.first { candidates.append(phone) }
                if let best = candidates.first { mapping[key] = best }
            }
        }
        names = mapping
    }

    func name(for hashedID: String?) -> String? {
        guard let hashedID else { return nil }
        return names[hashedID]
    }
}
