import DigUpKit
import Foundation

struct CLIError: Error { let message: String; init(_ message: String) { self.message = message } }
struct Arguments {
    var indexFolder: URL
    var positional: [String] = []
    var lists: [String: [String]] = [:]
    var values: [String: String] = [:]
    static func folderURL(_ path: String) -> URL { URL(fileURLWithPath: path) }
    static func isFolder(_ url: URL) -> Bool { true }
    static func isReadable(_ url: URL) -> Bool { true }
}
func emit(_ fields: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: fields)
    try? FileHandle.standardOutput.write(contentsOf: data + [10])
}
final class ProbeState: @unchecked Sendable {
    var starts = 0
}
let probeState = ProbeState()
final class ProbeEmbedder: Embedder {
    let info = WorkerInfo(model: "fake", revision: "v1", runtime: "test", dtype: "f32", dim: 768,
                          textOnly: true, loadSeconds: 0)
    func embedTexts(_ texts: [String]) throws -> [[Float]] {
        emit(["event": "probe_embed", "text": texts.first ?? ""])
        Thread.sleep(forTimeInterval: 0.4)
        return texts.map { _ in [1] + Array(repeating: Float(0), count: 767) }
    }
    func embedImages(_ paths: [String], budget: Int) throws -> [Embedding] { [] }
    func embedAudio(_ paths: [String]) throws -> [Embedding] { [] }
    func close() {}
}
func makeEmbedder(textOnly: Bool, log: URL, qos: QualityOfService) throws -> any Embedder {
    probeState.starts += 1
    Thread.sleep(forTimeInterval: 0.4)
    if ProcessInfo.processInfo.environment["PROBE_FAIL_ONCE"] == "1", probeState.starts == 1 {
        throw CLIError("model has not arrived")
    }
    return ProbeEmbedder()
}
// The real service queue is exercised with a deterministic slow renderer rather than real model/media work.
enum PreviewImages {
    enum Kind: String { case image, pdf, video }
    static func make(_ kind: Kind, of path: String, at loc: Double?, pixels: Int, in folder: URL) throws -> String {
        Thread.sleep(forTimeInterval: 0.4)
        return folder.appendingPathComponent(UUID().uuidString).path
    }
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let service = try SearchService(index: folder, roots: [], skipped: [], types: [], codeRoots: [], codeSkipped: [],
                                idleSeconds: 300)
emit(["event": "ready"])
exit(service.serve())
