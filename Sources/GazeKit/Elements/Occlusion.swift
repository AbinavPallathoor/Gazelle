import Foundation

/// An on-screen window from the window server, front-to-back order.
public struct WindowInfo: Equatable, Sendable {
    public var pid: Int32
    public var layer: Int
    /// Global top-left points.
    public var frame: Rect2

    public init(pid: Int32, layer: Int, frame: Rect2) {
        self.pid = pid
        self.layer = layer
        self.frame = frame
    }
}

public enum Occlusion {
    /// The frontmost window containing `p`. `windows` must be ordered front to back.
    public static func topmostWindow(at p: Point2, in windows: [WindowInfo]) -> WindowInfo? {
        windows.first { $0.frame.contains(p) }
    }

    /// Drops window elements hidden behind other apps' windows, and trims partly covered ones.
    ///
    /// An element is kept if, at a majority of its sample points (centre plus four points inset
    /// a quarter of the way in), the topmost window belongs to the element's own process.
    /// A kept element is then trimmed where another app's window covers one whole side of it,
    /// so its box matches what is actually visible.
    /// Elements from the menu bar, menu extras and Dock sit on high window layers and are
    /// kept as long as they are on a screen.
    /// - Parameter ignoringPID: our own process; its overlay windows never occlude.
    public static func visibleElements(_ elements: [Element], windows: [WindowInfo], screens: [Rect2],
                                       ignoringPID: Int32) -> [Element] {
        let stack = windows.filter { $0.pid != ignoringPID }
        return elements.compactMap { e -> Element? in
            guard screens.contains(where: { $0.intersects(e.frame) }) else { return nil }
            guard e.source == .window else { return e }
            let f = e.frame
            let points = [
                Point2(f.x + f.width / 2, f.y + f.height / 2),
                Point2(f.x + f.width / 4, f.y + f.height / 4),
                Point2(f.x + 3 * f.width / 4, f.y + f.height / 4),
                Point2(f.x + f.width / 4, f.y + 3 * f.height / 4),
                Point2(f.x + 3 * f.width / 4, f.y + 3 * f.height / 4),
            ]
            let own = points.filter { topmostWindow(at: $0, in: stack)?.pid == e.pid }.count
            guard own * 2 > points.count else { return nil }

            // Windows of other apps in front of the element's own window.
            let center = points[0]
            guard let ownIndex = stack.firstIndex(where: { $0.pid == e.pid && $0.frame.contains(center) }) else { return e }
            var trimmed = e
            trimmed.frame = stack[..<ownIndex]
                .filter { $0.pid != e.pid }
                .reduce(f) { trim($0, by: $1.frame) }
            return trimmed.frame.isEmpty ? nil : trimmed
        }
    }

    /// Removes the part of `r` covered by `o` when `o` spans one full side of `r`
    /// (a non-rectangular remainder is left untouched).
    static func trim(_ r: Rect2, by o: Rect2) -> Rect2 {
        guard r.intersects(o) else { return r }
        var out = r
        if o.minY <= r.minY && o.maxY >= r.maxY {            // covers full height: cut left or right
            if o.minX > r.minX { out = Rect2(x: r.minX, y: r.minY, width: o.minX - r.minX, height: r.height) }
            else if o.maxX < r.maxX { out = Rect2(x: o.maxX, y: r.minY, width: r.maxX - o.maxX, height: r.height) }
        } else if o.minX <= r.minX && o.maxX >= r.maxX {     // covers full width: cut top or bottom
            if o.minY > r.minY { out = Rect2(x: r.minX, y: r.minY, width: r.width, height: o.minY - r.minY) }
            else if o.maxY < r.maxY { out = Rect2(x: r.minX, y: o.maxY, width: r.width, height: r.maxY - o.maxY) }
        }
        return out
    }
}
