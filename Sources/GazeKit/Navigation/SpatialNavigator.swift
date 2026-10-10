import Foundation

public enum Direction: String, Sendable, CaseIterable {
    case left, right, up, down
}

/// Directional and reading-order navigation between element boxes (global top-left points).
///
/// Directional moves follow the idea of spatial focus navigation: only elements that lie
/// further in the pressed direction are candidates. Elements that share the current element's
/// row (for left/right) or column (for up/down) are preferred; only if there are none do
/// elements inside a cone around the direction compete. Within a tier the best candidate
/// minimises the gap along the direction plus a heavier penalty for being off to the side.
/// Elements that contain the current one (its row, a group) are never candidates.
public enum SpatialNavigator {
    /// Off-axis distance costs this much more than on-axis distance.
    public static let orthogonalWeight = 3.0
    /// Cone half-angle: candidates whose off-axis centre offset exceeds this multiple of the
    /// on-axis centre distance are ignored unless they overlap the current element across the axis.
    /// 0.75 ≈ 37°: wide enough for loosely aligned layouts, narrow enough that "right" from a
    /// list item does not jump up to a toolbar control.
    public static let coneSlope = 0.75
    /// Minimum allowed sideways gap for fallback candidates, in points.
    public static let maxSidewaysGapFloor = 40.0

    public static func move(from current: Rect2, _ direction: Direction, among candidates: [Element],
                            excluding currentID: UInt64? = nil) -> Element? {
        let c = current.center
        var bestAligned: (Element, Double)?
        var bestInCone: (Element, Double)?
        for e in candidates where e.id != currentID {
            let f = e.frame
            if f.minX <= current.minX && f.minY <= current.minY && f.maxX >= current.maxX && f.maxY >= current.maxY {
                continue // container of the current element
            }
            let p = f.center
            // Signed distances along the direction (primary) and across it (orthogonal).
            let (primaryCenter, gap, orthOverlap, orthGap, orthCenter): (Double, Double, Double, Double, Double)
            switch direction {
            case .right:
                (primaryCenter, gap) = (p.x - c.x, f.minX - current.maxX)
                (orthOverlap, orthGap, orthCenter) = intervals(current.minY, current.maxY, f.minY, f.maxY, c.y, p.y)
            case .left:
                (primaryCenter, gap) = (c.x - p.x, current.minX - f.maxX)
                (orthOverlap, orthGap, orthCenter) = intervals(current.minY, current.maxY, f.minY, f.maxY, c.y, p.y)
            case .down:
                (primaryCenter, gap) = (p.y - c.y, f.minY - current.maxY)
                (orthOverlap, orthGap, orthCenter) = intervals(current.minX, current.maxX, f.minX, f.maxX, c.x, p.x)
            case .up:
                (primaryCenter, gap) = (c.y - p.y, current.minY - f.maxY)
                (orthOverlap, orthGap, orthCenter) = intervals(current.minX, current.maxX, f.minX, f.maxX, c.x, p.x)
            }
            // Must lie further along the direction: its centre beyond ours, and both its near and
            // far edges beyond ours. The near-edge rule stops a wider box in the same column
            // (e.g. a longer file name below) from counting as "to the right".
            guard primaryCenter > 0.5 else { continue }
            let edgesBeyond: Bool
            switch direction {
            case .right: edgesBeyond = f.minX > current.minX && f.maxX > current.maxX
            case .left: edgesBeyond = f.maxX < current.maxX && f.minX < current.minX
            case .down: edgesBeyond = f.minY > current.minY && f.maxY > current.maxY
            case .up: edgesBeyond = f.maxY < current.maxY && f.minY < current.minY
            }
            guard edgesBeyond else { continue }
            if orthOverlap <= 0 {
                // Fallback tier: within the cone and not far off to the side (relative to the
                // current element's size across the axis), so presses never jump diagonally
                // across the window. Tab reaches anything arrows cannot.
                let across = (direction == .left || direction == .right) ? current.height : current.width
                guard orthCenter <= coneSlope * primaryCenter,
                      orthGap <= max(2 * across, maxSidewaysGapFloor) else { continue }
            }

            let score = max(0, gap) + orthogonalWeight * orthGap + 0.1 * orthCenter + 0.01 * primaryCenter
            if orthOverlap > 0 {
                if bestAligned == nil || score < bestAligned!.1 { bestAligned = (e, score) }
            } else if bestInCone == nil || score < bestInCone!.1 {
                bestInCone = (e, score)
            }
        }
        return (bestAligned ?? bestInCone)?.0
    }

    /// Returns (overlap length, gap length, |centre offset|) of two intervals across the axis.
    private static func intervals(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double,
                                  _ ac: Double, _ bc: Double) -> (Double, Double, Double) {
        let overlap = min(a1, b1) - max(a0, b0)
        return (max(0, overlap), max(0, -overlap), abs(bc - ac))
    }

    /// Elements in reading order: lines top to bottom, left to right within a line.
    /// Two elements share a line when they overlap vertically by at least half the smaller height.
    public static func readingOrder(_ elements: [Element]) -> [Element] {
        let sorted = elements.sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
        var lines: [(minY: Double, maxY: Double, items: [Element])] = []
        for e in sorted {
            let f = e.frame
            if let i = lines.indices.last, sameLine(lines[i].minY, lines[i].maxY, f) {
                lines[i].items.append(e)
                lines[i].maxY = max(lines[i].maxY, f.maxY)
            } else {
                lines.append((f.minY, f.maxY, [e]))
            }
        }
        return lines.flatMap { $0.items.sorted { $0.frame.minX < $1.frame.minX } }
    }

    private static func sameLine(_ minY: Double, _ maxY: Double, _ f: Rect2) -> Bool {
        let overlap = min(maxY, f.maxY) - max(minY, f.minY)
        return overlap >= 0.5 * min(maxY - minY, f.height)
    }

    /// The next (or previous) element in reading order, wrapping around.
    public static func step(from currentID: UInt64?, forward: Bool, among elements: [Element]) -> Element? {
        let order = readingOrder(elements)
        guard !order.isEmpty else { return nil }
        guard let id = currentID, let i = order.firstIndex(where: { $0.id == id }) else {
            return forward ? order.first : order.last
        }
        let j = (i + (forward ? 1 : -1) + order.count) % order.count
        return order[j]
    }

    /// The element nearest to a point (0 if inside), preferring the smallest box among ties
    /// so a button wins over the row that contains it.
    public static func nearest(to p: Point2, among elements: [Element]) -> Element? {
        elements.min { a, b in
            let da = distance(p, a.frame), db = distance(p, b.frame)
            return da != db ? da < db : a.frame.area < b.frame.area
        }
    }

    public static func distance(_ p: Point2, _ r: Rect2) -> Double {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
