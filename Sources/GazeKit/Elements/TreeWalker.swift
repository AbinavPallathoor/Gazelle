import Foundation

/// The attributes of one accessibility node, fetched in a single round trip.
public struct NodeSnapshot: Sendable {
    public var role: String
    public var subrole: String?
    /// Global top-left points. Nil when the node has no position/size.
    public var frame: Rect2?
    public var title: String?
    public var identity: UInt64
    public var isHidden: Bool
    /// For menu bar items: whether its menu is open.
    public var isSelected: Bool

    public init(role: String, subrole: String? = nil, frame: Rect2?, title: String? = nil,
                identity: UInt64, isHidden: Bool = false, isSelected: Bool = false) {
        self.role = role
        self.subrole = subrole
        self.frame = frame
        self.title = title
        self.identity = identity
        self.isHidden = isHidden
        self.isSelected = isSelected
    }
}

/// An accessibility tree node. The app implements it with `AXUIElement`; tests use in-memory trees.
public protocol ElementNode {
    /// Nil if the node did not answer (timeout, destroyed, no permission).
    func snapshot() -> NodeSnapshot?
    /// Children. With `visibleOnly`, containers that support it return only visible
    /// rows/children (`AXVisibleRows`, `AXVisibleChildren`), which avoids walking long lists.
    func children(visibleOnly: Bool) -> [Self]
    func actions() -> [String]
}

public struct WalkLimits: Sendable {
    public var maxDepth: Int
    public var maxNodes: Int
    /// Elements whose visible part is smaller than this in either dimension are dropped.
    public var minSide: Double

    public init(maxDepth: Int = 48, maxNodes: Int = 6000, minSide: Double = 4) {
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
        self.minSide = minSide
    }
}

public struct WalkResult: Sendable {
    public var elements: [Element] = []
    public var visitedNodes = 0
    /// True if `maxNodes` stopped the walk early.
    public var truncated = false
}

/// Breadth-first walk that keeps interactive elements and prunes what cannot be on screen.
///
/// - Windows and scroll areas narrow the clip rectangle for their descendants, so content
///   scrolled out of view or outside its window is dropped, and its subtree is not walked
///   when the container itself has a frame outside the clip.
/// - Tables, outlines and lists are walked through their visible rows/children only.
/// - Closed menus (under menu bar items that are not selected) are not walked.
/// - Breadth-first, so a node cap spends its budget evenly instead of inside one deep subtree.
public enum TreeWalker {
    struct ParentInfo {
        var isNativeList: Bool
    }

    static let visibleOnlyRoles: Set<String> = ["AXTable", "AXOutline", "AXList", "AXGrid", "AXBrowser"]
    static let clippingRoles: Set<String> = ["AXWindow", "AXScrollArea", "AXSheet", "AXDrawer"]

    /// - Parameter onElement: called with each emitted element and its node, so callers can keep
    ///   a handle for performing actions later.
    public static func walk<N: ElementNode>(roots: [(node: N, source: ElementSource)], pid: Int32,
                                             clip: Rect2, limits: WalkLimits = WalkLimits(),
                                             onElement: (Element, N) -> Void = { _, _ in }) -> WalkResult {
        var result = WalkResult()
        // `inRow`: inside a table/outline row or a cell, where text fields are item labels
        // (e.g. Finder file names) and the row itself is the thing to act on.
        var queue: [(node: N, source: ElementSource, clip: Rect2, depth: Int, inRow: Bool, parent: ParentInfo?)] =
            roots.map { ($0.node, $0.source, clip, 0, false, nil) }
        var head = 0
        var seen = Set<UInt64>()

        while head < queue.count {
            if result.visitedNodes >= limits.maxNodes {
                result.truncated = true
                break
            }
            let (node, source, parentClip, depth, inRow, parentListRole) = queue[head]
            head += 1
            result.visitedNodes += 1
            guard let snap = node.snapshot(), !snap.isHidden else { continue }
            guard seen.insert(snap.identity).inserted else { continue }

            var clip = parentClip
            if let frame = snap.frame, !frame.isEmpty {
                guard let visible = frame.intersection(parentClip) else { continue } // off-screen subtree
                if clippingRoles.contains(snap.role) { clip = visible }
            }

            var descend = depth < limits.maxDepth && !ElementClassifier.opaqueRoles.contains(snap.role)
            var childInRow = inRow
            var kind = ElementClassifier.kind(role: snap.role, subrole: snap.subrole, source: source, actions: node.actions)
            // Items of a native list (e.g. Finder's column view) are groups with no role of their
            // own. Web lists (subrole AXContentList) are skipped: their links are the targets.
            if kind == nil, snap.role == "AXGroup", let parent = parentListRole, parent.isNativeList {
                kind = .cell
            }
            if let kind {
                if kind == .row || kind == .cell { childInRow = true }
                if kind == .textField && inRow {
                    descend = false
                } else if let frame = snap.frame, let visible = frame.intersection(parentClip),
                   visible.width >= limits.minSide, visible.height >= limits.minSide {
                    let element = Element(id: snap.identity, kind: kind, frame: visible,
                                          title: snap.title, pid: pid, source: source)
                    result.elements.append(element)
                    onElement(element, node)
                }
                if ElementClassifier.isLeaf(kind) { descend = false }
            }
            if snap.role == "AXMenuBarItem" { descend = snap.isSelected && depth < limits.maxDepth }

            guard descend else { continue }
            let kids = node.children(visibleOnly: visibleOnlyRoles.contains(snap.role))
            let info = ParentInfo(isNativeList: snap.role == "AXList" && snap.subrole != "AXContentList")
            for k in kids { queue.append((k, source, clip, depth + 1, childInRow, info)) }
        }
        return result
    }
}
