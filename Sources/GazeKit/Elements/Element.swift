import Foundation

/// What kind of interactive element this is. Drives debug colours, navigation and actions.
public enum ElementKind: String, Codable, Sendable, CaseIterable {
    case button
    case link
    case checkbox
    case radio
    case tab
    case popUp
    case menuItem
    case menuBarItem
    case statusItem
    case dockItem
    case textField
    case row
    case cell
    case slider
    case disclosure
    /// Any other element that advertises a press/open/pick action.
    case pressable

    public var isEditable: Bool { self == .textField }
}

/// Where an element was found.
public enum ElementSource: String, Codable, Sendable {
    case window
    case menuBar
    case menuExtras
    case dock
}

/// One clickable or editable element on screen.
/// Frames are in global top-left points (see `ScreenSpace`).
public struct Element: Equatable, Sendable, Identifiable {
    /// Stable for the same underlying UI element across refreshes (derived from the AX element hash).
    public var id: UInt64
    public var kind: ElementKind
    /// The part of the element that is visible (clipped by its window and scroll areas).
    public var frame: Rect2
    public var title: String?
    public var pid: Int32
    public var source: ElementSource

    public init(id: UInt64, kind: ElementKind, frame: Rect2, title: String? = nil, pid: Int32, source: ElementSource) {
        self.id = id
        self.kind = kind
        self.frame = frame
        self.title = title
        self.pid = pid
        self.source = source
    }
}

/// Maps Accessibility roles to element kinds.
public enum ElementClassifier {
    /// Roles whose `AXActions` are worth fetching to decide whether they are clickable.
    /// Kept small: fetching actions costs one more IPC round trip per node. Static text is
    /// excluded because web pages have thousands of text nodes; clickable text sits inside an
    /// `AXLink` or `AXButton`, which is found anyway.
    public static let actionProbeRoles: Set<String> = ["AXImage", "AXCell"]

    /// Roles whose children never contain interactive elements (Chromium nests inline text
    /// boxes under every text node).
    public static let opaqueRoles: Set<String> = ["AXStaticText", "AXImage", "AXScrollBar", "AXSplitter", "AXValueIndicator"]
    public static let clickActions: Set<String> = ["AXPress", "AXOpen", "AXPick", "AXConfirm"]

    public static func kind(role: String, subrole: String?, source: ElementSource, actions: () -> [String]) -> ElementKind? {
        switch role {
        case "AXButton", "AXMenuButton":
            return subrole == "AXTabButton" ? .tab : .button
        case "AXLink": return .link
        case "AXCheckBox": return .checkbox // includes AXSwitch/AXToggle subroles
        case "AXRadioButton": return subrole == "AXTabButton" ? .tab : .radio
        case "AXPopUpButton", "AXComboBox", "AXColorWell", "AXDateField": return .popUp
        case "AXMenuItem": return .menuItem
        case "AXMenuBarItem": return source == .menuExtras ? .statusItem : .menuBarItem
        case "AXDockItem": return .dockItem
        case "AXTextField", "AXTextArea", "AXSearchField", "AXSecureTextField": return .textField
        case "AXRow": return .row
        case "AXSlider", "AXIncrementor", "AXStepper": return .slider
        case "AXDisclosureTriangle": return .disclosure
        default:
            guard actionProbeRoles.contains(role) else { return nil }
            let acts = actions()
            guard acts.contains(where: clickActions.contains) else { return nil }
            return role == "AXCell" ? .cell : .pressable
        }
    }

    /// Kinds whose children are not worth walking (their contents are labels or closed menus).
    public static func isLeaf(_ kind: ElementKind) -> Bool {
        switch kind {
        case .row, .cell, .pressable: return false
        default: return true
        }
    }
}
