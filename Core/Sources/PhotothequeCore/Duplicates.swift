import Foundation

/// Groupe de photos semblables (empreinte visuelle proche). Jamais de suppression automatique.
public struct SimilarGroup: Identifiable, Hashable, Sendable {
    public var photos: [Photo]
    public var maxDistance: Int
    public var id: Int64 { photos.first?.id ?? 0 }
}

extension Catalog {
    /// Photos dont l'empreinte visuelle (dHash) diffère d'au plus `threshold` bits sur 64.
    /// 0 = quasi identiques ; 10 = même image retouchée, réduite ou réenregistrée.
    public func similarGroups(threshold: Int = 8) throws -> [SimilarGroup] {
        let rows = try db.query("SELECT * FROM photos WHERE dhash IS NOT NULL ORDER BY id").map(Photo.init(row:))
        let hashes = rows.map { UInt64($0.dhash ?? "", radix: 16) }
        var parent = Array(0..<rows.count)
        func find(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        var worst: [Int: Int] = [:]
        for i in 0..<rows.count {
            guard let a = hashes[i] else { continue }
            for j in (i + 1)..<max(i + 1, rows.count) {
                guard let b = hashes[j] else { continue }
                let d = (a ^ b).nonzeroBitCount
                if d <= threshold {
                    let ri = find(i), rj = find(j)
                    let root = min(ri, rj)
                    parent[max(ri, rj)] = root
                    worst[root] = max(worst[root] ?? 0, worst[max(ri, rj)] ?? 0, d)
                }
            }
        }
        var groups: [Int: [Photo]] = [:]
        for i in 0..<rows.count { groups[find(i), default: []].append(rows[i]) }
        return groups.filter { $0.value.count > 1 }
            .map { SimilarGroup(photos: $0.value, maxDistance: worst[$0.key] ?? 0) }
            .sorted { $0.photos[0].id < $1.photos[0].id }
    }

    /// Photos qui n'ont pas encore d'empreinte visuelle (à calculer par l'application).
    public func photosWithoutDHash(limit: Int = 500) throws -> [Photo] {
        try db.query("SELECT * FROM photos WHERE dhash IS NULL ORDER BY id LIMIT ?", [.of(limit)]).map(Photo.init(row:))
    }
}
