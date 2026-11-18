import CoreGraphics
import Foundation

/// How to pick one zone when the cursor is inside several overlapping zones (e.g. Focus layouts).
enum OverlapResolution: String, CaseIterable {
    case smallest, largest, positional

    var title: String {
        switch self {
        case .smallest: return "Smallest zone"
        case .largest: return "Largest zone"
        case .positional: return "Nearest zone center"
        }
    }
}

extension Prefs {
    static let overlapResolutionKey = "overlapResolution"

    static var overlapResolution: OverlapResolution {
        OverlapResolution(rawValue: UserDefaults.standard.string(forKey: overlapResolutionKey) ?? "") ?? .smallest
    }
}

enum ZoneResolution {
    /// Pure: the zone under `point`. A zone counts when the point is inside its rect; if several do (overlap),
    /// `policy` picks one (ties go to the lowest index). If none does, the gap counts as part of the first
    /// zone whose rect inflated by `gap / 2` contains the point (the pre-overlap-setting behavior), so
    /// non-overlapping layouts resolve exactly as before regardless of `policy`.
    static func primaryZone(at point: CGPoint, in zones: [CGRect], gap: CGFloat,
                            policy: OverlapResolution = .smallest) -> ZoneIndex? {
        let hits = zones.indices.filter { zones[$0].contains(point) }
        switch hits.count {
        case 0:
            let slack = gap / 2
            return zones.indices.first { zones[$0].insetBy(dx: -slack, dy: -slack).contains(point) }
        case 1:
            return hits[0]
        default:
            return hits.min { a, b in
                let ka = key(zones[a], point, policy), kb = key(zones[b], point, policy)
                return ka != kb ? ka < kb : a < b
            }
        }
    }

    /// Lower key wins.
    private static func key(_ r: CGRect, _ p: CGPoint, _ policy: OverlapResolution) -> CGFloat {
        switch policy {
        case .smallest: return r.width * r.height
        case .largest: return -(r.width * r.height)
        case .positional: return hypot(r.midX - p.x, r.midY - p.y)
        }
    }
}
