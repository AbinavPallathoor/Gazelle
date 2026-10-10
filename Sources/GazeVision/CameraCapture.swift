import AVFoundation
import CoreMedia
import Foundation

public enum CameraError: Error, CustomStringConvertible {
    case notAuthorized
    case noCamera
    case cannotAddInput
    case cannotAddOutput

    public var description: String {
        switch self {
        case .notAuthorized: return "Camera access was denied. Allow it in System Settings → Privacy & Security → Camera."
        case .noCamera: return "No camera found."
        case .cannotAddInput: return "Could not add camera input."
        case .cannotAddOutput: return "Could not add video output."
        }
    }
}

/// Webcam capture on a dedicated serial queue. Late frames are dropped, never queued.
/// Frames are handed to `onFrame` and never retained or written anywhere.
public final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    public let queue = DispatchQueue(label: "gazelle.camera", qos: .userInteractive)
    private let session = AVCaptureSession()
    /// Called on `queue` with each frame and its capture time in seconds (host clock).
    public var onFrame: ((CVPixelBuffer, Double) -> Void)?

    public override init() { super.init() }

    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    public func start(width: Int32 = 1280, height: Int32 = 720, fps: Double = 30) async throws {
        guard await Self.requestAccess() else { throw CameraError.notAuthorized }
        guard let device = AVCaptureDevice.default(for: .video) else { throw CameraError.noCamera }
        try configure(device: device, width: width, height: height, fps: fps)
        session.startRunning()
        try device.lockForConfiguration()
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
    }

    private func configure(device: AVCaptureDevice, width: Int32, height: Int32, fps: Double) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
        session.addInput(input)

        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            // Without explicit dimensions macOS delivers the sensor's native size, ignoring the preset.
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CameraError.cannotAddOutput }
        session.addOutput(output)
    }

    public func stop() {
        session.stopRunning()
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        onFrame?(pb, t)
    }
}
