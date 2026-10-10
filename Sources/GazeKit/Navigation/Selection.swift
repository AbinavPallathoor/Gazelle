import Foundation

/// The selected element, kept consistent as the element map refreshes.
public struct SelectionModel: Equatable, Sendable {
    public private(set) var elements: [Element] = []
    public private(set) var selected: Element?

    public init() {}

    /// Starts a selection: the focused element if known, else the element nearest the pointer.
    public mutating func begin(elements: [Element], focusedID: UInt64?, focusedFrame: Rect2?, pointer: Point2?) {
        self.elements = elements
        if let id = focusedID, let e = elements.first(where: { $0.id == id }) {
            selected = e
        } else if let f = focusedFrame {
            selected = SpatialNavigator.nearest(to: f.center, among: elements)
        } else if let p = pointer {
            selected = SpatialNavigator.nearest(to: p, among: elements)
        } else {
            selected = SpatialNavigator.readingOrder(elements).first
        }
    }

    /// Applies a refreshed element list. The selection follows the same element (by id) with its
    /// new frame; if it disappeared, the element nearest its old position is selected instead.
    public mutating func update(elements: [Element]) {
        self.elements = elements
        guard let old = selected else { return }
        if let same = elements.first(where: { $0.id == old.id }) {
            selected = same
        } else {
            selected = SpatialNavigator.nearest(to: old.frame.center, among: elements)
        }
    }

    /// Returns true if the selection changed.
    @discardableResult
    public mutating func move(_ direction: Direction) -> Bool {
        guard let cur = selected else {
            selected = SpatialNavigator.readingOrder(elements).first
            return selected != nil
        }
        guard let next = SpatialNavigator.move(from: cur.frame, direction, among: elements, excluding: cur.id) else {
            return false
        }
        selected = next
        return true
    }

    @discardableResult
    public mutating func step(forward: Bool) -> Bool {
        guard let next = SpatialNavigator.step(from: selected?.id, forward: forward, among: elements) else { return false }
        let changed = next.id != selected?.id
        selected = next
        return changed
    }

    public mutating func clear() {
        selected = nil
        elements = []
    }
}
