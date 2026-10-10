// gazespike — M0 throwaway harness for comparing vision backends.
//
//   gazespike record --backend vision|mediapipe --label still|moving [--seconds 60] [--delegate GPU|CPU]
//   gazespike analyze recordings/*.jsonl
//
// Recordings contain numeric features only. Camera frames are never written anywhere.

import AppKit
import Foundation
import GazeKit
import GazeVision

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("gazespike: \(msg)\n".utf8))
    exit(1)
}

func usage() -> Never {
    fail("""
    usage:
      gazespike record --backend vision|mediapipe [--label still] [--seconds 60] [--countdown 3] [--delegate GPU|CPU] [--out recordings]
      gazespike analyze <file.jsonl>...
    """)
}

func options(_ args: ArraySlice<String>) -> [String: String] {
    var out: [String: String] = [:]
    var it = args.makeIterator()
    while let k = it.next() {
        guard k.hasPrefix("--"), let v = it.next() else { usage() }
        out[String(k.dropFirst(2))] = v
    }
    return out
}

let args = CommandLine.arguments
guard args.count >= 2 else { usage() }

switch args[1] {
case "analyze":
    let files = args.dropFirst(2)
    guard !files.isEmpty else { usage() }
    print(SessionMetrics.tableHeader)
    for path in files {
        do {
            let rec = try Recording.decode(jsonl: Data(contentsOf: URL(fileURLWithPath: path)))
            print(SessionMetrics(recording: rec).tableRow)
        } catch {
            fail("\(path): \(error)")
        }
    }

case "record":
    let o = options(args.dropFirst(2))
    guard let backend = Backend(rawValue: o["backend"] ?? "") else { usage() }
    let config = Recorder.Config(
        backend: backend,
        label: o["label"] ?? "still",
        seconds: Double(o["seconds"] ?? "60") ?? 60,
        countdown: Double(o["countdown"] ?? "3") ?? 3,
        delegate: o["delegate"] ?? "GPU",
        outDir: URL(fileURLWithPath: o["out"] ?? "recordings"))
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let recorder = MainActor.assumeIsolated { Recorder(config: config) }
    Task { @MainActor in
        await recorder.run()
        exit(0)
    }
    app.run()

default:
    usage()
}
