import AppKit
import ApplicationServices
import Combine
import GazeKit
import os

private let log = Logger(subsystem: "dev.gazelle.Gazelle", category: "elements")

/// The always-current set of on-screen elements.
///
/// Refreshes are event-driven, never a fixed-rate poll:
/// - `AXObserver` notifications from the frontmost app (window moved/resized/created, focus,
///   value, layout, menus, element destroyed);
/// - app activation, launch and termination, and display changes;
/// - scroll-wheel and mouse-up events (many apps post no AX notification when content scrolls).
/// Changes are coalesced and scans run on a background queue, so neither Gazelle's UI nor the
/// target app is blocked; each AX call also has a short messaging timeout.
@MainActor
final class ElementStore: ObservableObject {
    /// Frontmost-app elements plus menu extras and Dock.
    @Published private(set) var elements: [Element] = []
    @Published private(set) var stats = ScanStats()
    @Published private(set) var lacksPermission = false
    /// Accessibility handles for `elements`, for performing actions.
    private(set) var refs: ElementRefs = [:]
    private var frontmostRefs: ElementRefs = [:]
    private var systemRefs: ElementRefs = [:]
    private(set) var isRunning = false

    private let scanner = ElementScanner()
    private let queue = DispatchQueue(label: "gazelle.elements", qos: .userInitiated)
    private let systemQueue = DispatchQueue(label: "gazelle.elements.system", qos: .utility)
    private var frontmostElements: [Element] = []
    private var systemElements: [Element] = []
    private var systemScanInFlight = false
    private var systemTimer: Timer?
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var eventMonitor: Any?
    private var debounce: DispatchWorkItem?
    private var scanInFlight = false
    private var rescanRequested = false
    /// Uptime of the first change not yet reflected in `elements`.
    private var pendingSince: UInt64?
    /// A just-launched app answers AX requests (and accepts observers) only after a moment.
    /// Near-empty scans and failed observer registration are retried with backoff.
    private var retryCount = 0
    private var observerAttached = false
    static let retryDelays = [0.25, 0.5, 1.0, 2.0]

    static let debounceSeconds = 0.03
    /// Menu extras and the Dock also refresh on app launch/quit and display changes.
    static let systemRefreshSeconds = 10.0
    static let notifications = [
        kAXWindowMovedNotification, kAXWindowResizedNotification, kAXWindowCreatedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
        kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification,
        kAXMainWindowChangedNotification, kAXValueChangedNotification, kAXUIElementDestroyedNotification,
        kAXCreatedNotification, kAXMenuOpenedNotification, kAXMenuClosedNotification,
        kAXSelectedChildrenChangedNotification, kAXSelectedRowsChangedNotification,
        kAXRowCountChangedNotification, kAXLayoutChangedNotification, kAXTitleChangedNotification,
        // Web views (Safari, Chromium, Electron) finish loading after the first scan.
        "AXLoadComplete", "AXElementBusyChanged",
    ]

    func start() {
        guard !isRunning else { return }
        isRunning = true
        lacksPermission = !AXIsProcessTrusted()

        let nc = NSWorkspace.shared.notificationCenter
        workspaceTokens = [
            nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.frontmostChanged() }
            },
            nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteChange(system: true) }
            },
            nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteChange(system: true) }
            },
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteChange(system: true) }
            },
        ]
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .leftMouseUp, .rightMouseUp]) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteChange(delay: 0.08) }
        }
        systemTimer = Timer.scheduledTimer(withTimeInterval: Self.systemRefreshSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSystem() }
        }
        refreshSystem()
        frontmostChanged()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        workspaceTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
        workspaceTokens = []
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        removeObserver()
        debounce?.cancel()
        debounce = nil
        systemTimer?.invalidate()
        systemTimer = nil
        pendingSince = nil
        frontmostElements = []
        systemElements = []
        frontmostRefs = [:]
        systemRefs = [:]
        refs = [:]
        elements = []
    }

    /// Records a change and schedules a rescan a fixed delay after the *first* unserved change.
    /// Later changes in that window join the same scan instead of pushing it back, so a burst of
    /// notifications (e.g. while a window is dragged) cannot starve the refresh.
    /// Requests a prompt rescan (e.g. right after performing an action).
    func refreshSoon() { noteChange(delay: 0.05) }

    func noteChange(system: Bool = false, delay: Double = ElementStore.debounceSeconds) {
        guard isRunning else { return }
        if system { refreshSystem() }
        if pendingSince == nil { pendingSince = DispatchTime.now().uptimeNanoseconds }
        guard debounce == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.debounce = nil
                self?.runScan()
            }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func refreshSystem() {
        guard isRunning, !systemScanInFlight else { return }
        systemScanInFlight = true
        let screens = ElementScanner.screenRects()
        let scanner = scanner
        systemQueue.async { [weak self] in
            let (found, foundRefs) = scanner.scanSystem(screens: screens)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.systemScanInFlight = false
                    guard self.isRunning else { return }
                    self.systemElements = found
                    self.systemRefs = foundRefs
                    self.refs = self.frontmostRefs.merging(foundRefs) { a, _ in a }
                    self.elements = self.frontmostElements + found
                }
            }
        }
    }

    private func runScan() {
        guard isRunning else { return }
        if scanInFlight {
            rescanRequested = true
            return
        }
        scanInFlight = true
        let changeTime = pendingSince
        pendingSince = nil
        let app = NSWorkspace.shared.frontmostApplication
        let screens = ElementScanner.screenRects()
        let scanner = scanner
        lacksPermission = !AXIsProcessTrusted()

        queue.async { [weak self] in
            var (elements, elementRefs, stats) = scanner.scanFrontmost(app: app, screens: screens)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let changeTime {
                        stats.latencyMs = Double(DispatchTime.now().uptimeNanoseconds - changeTime) / 1e6
                    }
                    self.scanInFlight = false
                    guard self.isRunning else { return }
                    self.frontmostElements = elements
                    self.frontmostRefs = elementRefs
                    self.refs = elementRefs.merging(self.systemRefs) { a, _ in a }
                    self.elements = elements + self.systemElements
                    self.stats = stats
                    self.retryIfNotReady(app: app, stats: stats)
                    log.info("scan \(stats.appName, privacy: .public): \(stats.elements) elements, \(stats.visitedNodes) nodes, \(stats.durationMs, format: .fixed(precision: 1)) ms, change→publish \(stats.latencyMs ?? -1, format: .fixed(precision: 1)) ms")
                    if self.rescanRequested {
                        self.rescanRequested = false
                        self.noteChange()
                    }
                }
            }
        }
    }

    private func retryIfNotReady(app: NSRunningApplication?, stats: ScanStats) {
        guard let app, app.processIdentifier != getpid(),
              app == NSWorkspace.shared.frontmostApplication else { return }
        let notReady = stats.visitedNodes < 5 || !observerAttached
        guard notReady, retryCount < Self.retryDelays.count else {
            if !notReady { retryCount = 0 }
            return
        }
        let delay = Self.retryDelays[retryCount]
        retryCount += 1
        log.info("\(app.localizedName ?? "?", privacy: .public) not ready (\(stats.visitedNodes) nodes, observer \(self.observerAttached)); retry in \(delay) s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, NSWorkspace.shared.frontmostApplication == app else { return }
                if !self.observerAttached {
                    self.removeObserver()
                    self.addObserver(pid: app.processIdentifier)
                }
                self.noteChange()
            }
        }
    }

    // MARK: AX observer for the frontmost app

    private func frontmostChanged() {
        guard isRunning else { return }
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if pid != observedPID {
            removeObserver()
            retryCount = 0
            if let pid, pid != getpid() { addObserver(pid: pid) }
        }
        noteChange()
    }

    private func addObserver(pid: pid_t) {
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let store = Unmanaged<ElementStore>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { store.noteChange() }
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }
        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var attached = 0
        for n in Self.notifications where AXObserverAddNotification(obs, app, n as CFString, refcon) == .success {
            attached += 1
        }
        observerAttached = attached > 0
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        observedPID = pid
    }

    private func removeObserver() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedPID = nil
        observerAttached = false
    }
}
