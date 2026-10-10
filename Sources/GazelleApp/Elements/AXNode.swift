import ApplicationServices
import GazeKit

/// `ElementNode` backed by a live `AXUIElement`. All attributes a walk needs are fetched with
/// one `AXUIElementCopyMultipleAttributeValues` call per node to keep IPC round trips low.
struct AXNode: ElementNode {
    let element: AXUIElement

    private static let snapshotAttributes = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXPositionAttribute, kAXSizeAttribute,
        kAXTitleAttribute, kAXDescriptionAttribute, "AXHidden", kAXSelectedAttribute,
    ] as CFArray

    func snapshot() -> NodeSnapshot? {
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, Self.snapshotAttributes, AXCopyMultipleAttributeOptions(), &raw) == .success,
              let values = raw as? [AnyObject], values.count == 8,
              let role = Self.string(values[0]) else { return nil }

        var frame: Rect2?
        if let pos = Self.point(values[2]), let size = Self.size(values[3]) {
            frame = Rect2(x: pos.x, y: pos.y, width: size.width, height: size.height)
        }
        let title = [Self.string(values[4]), Self.string(values[5])].compactMap { $0 }.first { !$0.isEmpty }
        return NodeSnapshot(role: role, subrole: Self.string(values[1]), frame: frame,
                            title: title.map { String($0.prefix(60)) },
                            identity: UInt64(CFHash(element)),
                            isHidden: Self.bool(values[6]) ?? false,
                            isSelected: Self.bool(values[7]) ?? false)
    }

    func children(visibleOnly: Bool) -> [AXNode] {
        // Chromium reports AXVisibleRows/AXVisibleChildren as empty arrays on most web
        // elements, so an empty answer means "unsupported" and falls back to AXChildren.
        if visibleOnly {
            for attr in [kAXVisibleRowsAttribute, kAXVisibleChildrenAttribute] {
                if let kids = elements(attr), !kids.isEmpty { return kids }
            }
        }
        return elements(kAXChildrenAttribute) ?? []
    }

    func actions() -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    func elements(_ attribute: String) -> [AXNode]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let array = value as? [AXUIElement] else { return nil }
        return array.map(AXNode.init)
    }

    func element(_ attribute: String) -> AXNode? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return AXNode(element: v as! AXUIElement)
    }

    // MARK: value decoding

    private static func string(_ v: AnyObject) -> String? { v as? String }

    private static func bool(_ v: AnyObject) -> Bool? { (v as? NSNumber)?.boolValue }

    private static func point(_ v: AnyObject) -> CGPoint? {
        guard CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    private static func size(_ v: AnyObject) -> CGSize? {
        guard CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }
}
