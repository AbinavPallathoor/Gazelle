import Foundation

/// Metadata written as the first line of a recording.
public struct RecordingMeta: Codable, Sendable, Equatable {
    public var backend: String
    public var label: String
    public var startedAt: Date
    public var note: String?

    public init(backend: String, label: String, startedAt: Date, note: String? = nil) {
        self.backend = backend
        self.label = label
        self.startedAt = startedAt
        self.note = note
    }
}

/// Process CPU usage over a sampling interval, in percent of one core.
public struct CPUSample: Codable, Sendable, Equatable {
    public var timestamp: Double
    public var percent: Double

    public init(timestamp: Double, percent: Double) {
        self.timestamp = timestamp
        self.percent = percent
    }
}

/// One line of a JSONL feature recording. Exactly one field is set.
/// Recordings hold numbers only, never image data.
public struct RecordLine: Codable, Sendable, Equatable {
    public var meta: RecordingMeta?
    public var frame: FaceFeatures?
    public var cpu: CPUSample?

    public init(meta: RecordingMeta) { self.meta = meta }
    public init(frame: FaceFeatures) { self.frame = frame }
    public init(cpu: CPUSample) { self.cpu = cpu }
}

public struct Recording: Sendable {
    public var meta: RecordingMeta?
    public var frames: [FaceFeatures] = []
    public var cpu: [CPUSample] = []

    public init(meta: RecordingMeta? = nil, frames: [FaceFeatures] = [], cpu: [CPUSample] = []) {
        self.meta = meta
        self.frames = frames
        self.cpu = cpu
    }

    public static func encodeLine(_ line: RecordLine) throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        var d = try enc.encode(line)
        d.append(0x0A)
        return d
    }

    public static func decode(jsonl data: Data) throws -> Recording {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var rec = Recording()
        for slice in data.split(separator: 0x0A) where !slice.isEmpty {
            let line = try dec.decode(RecordLine.self, from: Data(slice))
            if let m = line.meta { rec.meta = m }
            if let f = line.frame { rec.frames.append(f) }
            if let c = line.cpu { rec.cpu.append(c) }
        }
        return rec
    }
}
