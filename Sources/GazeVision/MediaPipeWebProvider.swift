import Foundation
import GazeKit
import WebKit

public enum MediaPipeError: Error, CustomStringConvertible {
    case resourcesMissing
    case page(String)
    case webContentTerminated

    public var description: String {
        switch self {
        case .resourcesMissing: return "MediaPipe resources are missing from the bundle."
        case .page(let m): return "MediaPipe page error: \(m)"
        case .webContentTerminated: return "The MediaPipe web process terminated."
        }
    }
}

/// Face features from MediaPipe Face Landmarker, running the bundled WASM build inside a WKWebView.
/// The page opens the camera itself, so `webView` must sit in a window (it can be small) for
/// WebKit to keep delivering video frames. All assets load from the app bundle, and a content
/// rule list blocks http(s) and ws(s) loads. If the web process dies, the feature stream finishes.
@MainActor
public final class MediaPipeWebProvider: NSObject, FaceFeatureProvider, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate {
    public nonisolated let backendID = "mediapipe"
    public nonisolated let features: AsyncStream<FaceFeatures>
    private nonisolated let continuation: AsyncStream<FaceFeatures>.Continuation
    public let webView: WKWebView
    private var ready: CheckedContinuation<Void, Error>?
    /// "GPU" or "CPU" inference delegate.
    public let delegate: String

    public init(delegate: String = "GPU") {
        self.delegate = delegate
        (features, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        config.preferences.inactiveSchedulingPolicy = .none
        config.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 180), configuration: config)
        super.init()
        config.userContentController.add(self, name: "gaze")
        config.userContentController.addUserScript(WKUserScript(
            source: "window.__delegate = '\(delegate)';", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView.uiDelegate = self
        webView.navigationDelegate = self
    }

    /// Blocks http(s) and ws(s) loads; bundled file:// assets are unaffected.
    static let blockNetworkRules = """
        [{"trigger": {"url-filter": "^https?://"}, "action": {"type": "block"}},
         {"trigger": {"url-filter": "^wss?://"}, "action": {"type": "block"}}]
        """

    public func start() async throws {
        guard let dir = Bundle.module.url(forResource: "mediapipe", withExtension: nil) else {
            throw MediaPipeError.resourcesMissing
        }
        if let store = WKContentRuleListStore.default(),
           let rules = try await store.compileContentRuleList(forIdentifier: "gazelle.block-network",
                                                               encodedContentRuleList: Self.blockNetworkRules) {
            webView.configuration.userContentController.add(rules)
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            ready = c
            webView.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
        }
    }

    public func stop() {
        // Stop the camera tracks explicitly, then unload the page.
        webView.evaluateJavaScript(
            "document.getElementById('v')?.srcObject?.getTracks().forEach(t => t.stop())") { _, _ in }
        webView.loadHTMLString("", baseURL: nil)
        continuation.finish()
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let r = ready { r.resume(throwing: MediaPipeError.webContentTerminated); ready = nil }
        FileHandle.standardError.write(Data("mediapipe: \(MediaPipeError.webContentTerminated)\n".utf8))
        continuation.finish()
    }

    public func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let type = m["type"] as? String else { return }
        switch type {
        case "ready":
            ready?.resume()
            ready = nil
        case "error":
            let msg = m["message"] as? String ?? "unknown"
            if let r = ready { r.resume(throwing: MediaPipeError.page(msg)); ready = nil }
            else { FileHandle.standardError.write(Data("mediapipe: \(msg)\n".utf8)) }
        case "frame":
            continuation.yield(Self.parse(m))
        default:
            break
        }
    }

    static func parse(_ m: [String: Any]) -> FaceFeatures {
        func num(_ k: String) -> Double { (m[k] as? NSNumber)?.doubleValue ?? 0 }
        var f = FaceFeatures(timestamp: num("t"), backend: "mediapipe", confidence: 0, processingMs: num("ms"),
                             imageWidth: num("w"), imageHeight: num("h"))
        guard let pts = m["pts"] as? [String: [NSNumber]] else { return f }
        func p(_ k: String) -> Point2? {
            guard let a = pts[k], a.count == 2 else { return nil }
            return Point2(a[0].doubleValue, a[1].doubleValue)
        }
        func eye(_ s: String) -> EyeFeatures? {
            guard let inner = p(s + "Inner"), let outer = p(s + "Outer"), let iris = p(s + "Iris"),
                  let up = p(s + "Upper"), let lo = p(s + "Lower") else { return nil }
            let w = (outer - inner).length
            return EyeFeatures(inner: inner, outer: outer, iris: iris, openness: w > 0 ? (up - lo).length / w : 0)
        }
        f.leftEye = eye("a")
        f.rightEye = eye("b")
        if let b = (m["bbox"] as? [NSNumber])?.map(\.doubleValue), b.count == 4 {
            f.faceBounds = Rect2(x: b[0], y: b[1], width: b[2], height: b[3])
        }
        if let pose = (m["pose"] as? [NSNumber])?.map(\.doubleValue), pose.count == 3 {
            f.headPose = HeadPose(yaw: pose[0], pitch: pose[1], roll: pose[2])
        }
        f.confidence = f.leftEye != nil && f.rightEye != nil ? 1 : 0
        return f
    }

    public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                        initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                        decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(type == .camera ? .grant : .deny)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if let r = ready { r.resume(throwing: error); ready = nil }
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if let r = ready { r.resume(throwing: error); ready = nil }
    }
}
