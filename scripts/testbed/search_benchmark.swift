// Model-free search benchmark. Run with bash scripts/benchmark-search.sh.
// The same deterministic fixture runs against the baseline revision and current working tree.
import Foundation
import SQLite3
import Accelerate
@testable import DigUpKit

struct RNG {
    var state: UInt64 = 912_413_747
    mutating func vector() -> [Float] {
        var out = [Float](repeating: 0, count: 768)
        var norm: Double = 0
        for index in out.indices {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            out[index] = Float(Int32(truncatingIfNeeded: state >> 32)) / Float(Int32.max)
            norm += Double(out[index]) * Double(out[index])
        }
        let scale = Float(1 / sqrt(norm))
        return out.map { $0 * scale }
    }
}
func report(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
@discardableResult
func measure(_ name: String, repetitions: Int, prepare: (() throws -> Void)? = nil, body: () throws -> Double) rethrows -> Double {
    var timings: [Double] = [], sink = 0.0
    for _ in 0..<repetitions {
        try prepare?()
        let start = now()
        sink += try body()
        timings.append(Double(now() - start) / 1_000_000)
    }
    timings.sort()
    let median = timings[timings.count/2], p95 = timings[min(timings.count-1, Int(Double(timings.count)*0.95))]
    report(String(format: "%@ median=%.3fms p95=%.3fms n=%d sink=%.4f",name,median,p95,repetitions,sink))
    return median
}
func freshStore(_ name: String) throws -> IndexStore {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("fixtures/\(name)")
    try? FileManager.default.removeItem(at: root)
    return try IndexStore(directory: root)
}
func baselineRaw(_ matrix: VectorStorage, rows: Int, query: [Float], dimension: Int = 768) -> [Float] {
    var scores = [Float](repeating: 0, count: rows)
    query.withUnsafeBufferPointer { query in
        scores.withUnsafeMutableBufferPointer { scores in
            var row = 0
            while row < rows {
                let count = min(VectorStorage.blockRows, rows-row)
                Vectors.floats(fromHalf: matrix.halves + row*dimension, count: count*dimension, to: matrix.block)
                vDSP_mmul(matrix.block, 1, query.baseAddress!, 1, scores.baseAddress!+row, 1, vDSP_Length(count), 1, vDSP_Length(dimension))
                row += count
            }
        }
    }
    return scores
}
func benchmark(rows: Int) throws {
    let start = now(), store = try freshStore("bench-\(rows)")
    var rng = RNG()
    let bank = (0..<256).map { _ in rng.vector() }
    let query = bank[0]
    let files = rows/10
    try store.db.transaction {
        try store.db.execute("CREATE TABLE vector_bank(id INTEGER PRIMARY KEY, vec BLOB NOT NULL)")
        for (id, vec) in bank.enumerated() { try store.db.run("INSERT INTO vector_bank VALUES(?,?)", [.int(Int64(id)),.blob(Vectors.half(vec))]) }
        try store.db.execute("""
            WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x < \(files))
            INSERT INTO files(id,path,kind,size,mtime,inode,device,state) SELECT x,'/bench/file' || x || '.txt','doc',100,1,x,1,'done' FROM n;
            WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x < \(rows))
            INSERT INTO segments(id,file,kind,modality,loc,vec) SELECT x,(x-1)/10+1,'chunk','text',(x-1)%10+1,b.vec FROM n JOIN vector_bank b ON b.id=(x-1)%256;
            INSERT INTO fts(rowid,name,body) SELECT id,'','ordinary research content with enough additional context' FROM segments;
            DROP TABLE vector_bank;
            """)
    }
    try store.db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    report("FIXTURE rows=\(rows) files=\(files) dimensions=768 dtype=fp16 textVectors=100% bank=256 creationMs=\(Double(now()-start)/1_000_000) databaseBytes=\(IndexStore.size(of: store.file))")
    var searcher: Searcher?
    try measure("firstLoad[\(rows)]", repetitions: 1) { searcher = try Searcher(store: store); return Double(searcher!.vectorCount) }
    _ = try searcher!.search("", queryVector: query, limit: 40)
    try measure("warmReload[\(rows)]", repetitions: 7) { try searcher!.reload(); return Double(searcher!.vectorCount) }
    try measure("meaningSearch[\(rows)]", repetitions: 21) { let hits = try searcher!.search("", queryVector: query, limit: 40); return hits.first?.score ?? 0 }
    try measure("keywordSearchCommon[\(rows)]", repetitions: 21) { let hits = try searcher!.search("research", queryVector: nil, limit: 40); return Double(hits.count) }
    try measure("hybridSearchCommon[\(rows)]", repetitions: 21) { let hits = try searcher!.search("research", queryVector: query, limit: 40); return hits.first?.score ?? 0 }
    let matrix = VectorStorage(rows: rows)!
    for row in 0..<rows { Vectors.half(bank[row%256]).copyBytes(to: UnsafeMutableRawBufferPointer(start: matrix.halves + row*768, count:1536)) }
    let scores = baselineRaw(matrix, rows: rows, query: query)
    let modalities = [Modality](repeating: .text, count: rows), scale = [Bool](repeating: true, count: rows)
    measure("rawHalfDotProduct[\(rows)]", repetitions: 31) { Double(baselineRaw(matrix, rows: rows, query: query)[0]) }
    measure("statisticsMeaning[\(rows)]", repetitions: 31) { Searcher.meaning(scores, modalities, setsScale: scale)[0] }
    #if INCREMENTAL_SEARCH
    try measure("noOpRefresh[\(rows)]", repetitions: 101) { try searcher!.refresh(); return Double(searcher!.refreshedVectorRows) }
    try measure("oneFileAppendRefresh[\(rows)]", repetitions: 21, prepare: {
        try store.addSegment(file: 1, kind: .chunk, modality: .text, loc: 11, vector: bank[1])
    }) { try searcher!.refresh(); return Double(searcher!.refreshedVectorRows) }
    #endif
}

do {
    let requested = CommandLine.arguments.dropFirst().compactMap(Int.init)
    let sizes = requested.isEmpty ? [100_000] : requested
    for rows in sizes {
        guard rows > 0, rows % 10 == 0 else { throw Database.Failure(message: "row counts must be positive multiples of 10") }
        try benchmark(rows: rows)
    }
} catch { report("BENCHMARK ERROR \(error)"); exit(1) }
