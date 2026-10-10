import Foundation

extension Rect2 {
    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var area: Double { max(0, width) * max(0, height) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func contains(_ p: Point2) -> Bool {
        p.x >= minX && p.x < maxX && p.y >= minY && p.y < maxY
    }

    public func intersection(_ o: Rect2) -> Rect2? {
        let x0 = max(minX, o.minX), y0 = max(minY, o.minY)
        let x1 = min(maxX, o.maxX), y1 = min(maxY, o.maxY)
        guard x1 > x0, y1 > y0 else { return nil }
        return Rect2(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    public func intersects(_ o: Rect2) -> Bool { intersection(o) != nil }

    /// Smallest rectangle containing both.
    public func union(_ o: Rect2) -> Rect2 {
        let x0 = min(minX, o.minX), y0 = min(minY, o.minY)
        return Rect2(x: x0, y: y0, width: max(maxX, o.maxX) - x0, height: max(maxY, o.maxY) - y0)
    }
}

/// Conversions between the two global screen coordinate systems on macOS.
///
/// - **Top-left space** (Accessibility, CGWindowList, CGEvent): origin at the top-left of the
///   primary display, y grows downward, units are points.
/// - **AppKit space** (`NSScreen.frame`, `NSWindow.frame`): origin at the bottom-left of the
///   primary display, y grows upward.
///
/// Both share x, and are mirrored around the primary display's height.
public enum ScreenSpace {
    public static func appKitRect(fromTopLeft r: Rect2, primaryHeight h: Double) -> Rect2 {
        Rect2(x: r.x, y: h - r.y - r.height, width: r.width, height: r.height)
    }

    /// The mapping is its own inverse.
    public static func topLeftRect(fromAppKit r: Rect2, primaryHeight h: Double) -> Rect2 {
        appKitRect(fromTopLeft: r, primaryHeight: h)
    }

    public static func appKitPoint(fromTopLeft p: Point2, primaryHeight h: Double) -> Point2 {
        Point2(p.x, h - p.y)
    }
}
