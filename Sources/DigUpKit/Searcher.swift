import Foundation

public struct SearchHit: Sendable {
    public let path: String
    public let kind: FileKind
    public let score: Double          // fused rank score, for ordering only
    public let z: Double?             // how far the best segment stands out for this query (`Searcher.meaning`)
    public let cosine: Double?
    public let keywordRank: Int?      // 1-based rank among keyword matches
    public let segment: SegmentKind
    /// The segment the hit points at (its text is `Searcher.text(ofSegment:)`).
    public let segmentID: Int64
    public let loc: Double?           // PDF page, or seconds into audio/video
    public let locEnd: Double?
    public let excerpt: String?
    /// The file's modification date (seconds since 1970), and what indexing learned about it: "width", "height",
    /// "taken", "pages", "duration"… (see `Indexer`).
    public let modified: Double
    public let size: Int64
    public let info: [String: String]
    /// Code: the line to open at, in the stretch (`loc`…`locEnd`): where the name looked up is defined, or the first
    /// line with the query's words. Nil: the stretch's first line.
    public var focus: Double? = nil
}

/// Hybrid search: meaning (EmbeddingGemma's vectors) + words (FTS5).
///
/// Meaning is the model's cosine similarity, put on one scale per query (`meaning`): every vector is scored anyway, so
/// the distribution comes for free, and only segments that stand out (`zGate`) count as meaning matches. That also
/// gives an honest "nothing found". Words rescue what a vector can't hold exactly: codes, IDs and names.
public final class Searcher {
    /// Query vectors carry their source all the way to the loaded index snapshot.
    public struct QueryVector: Sendable {
        public let values: [Float]
        public let source: String
        public init(values: [Float], source: String) { self.values = values; self.source = source }
    }

    let store: IndexStore
    private var matrix: VectorStorage?
    private var rowFile: [Int64] = []
    private var rowSegment: [Int64] = []
    private var rowModality: [Modality] = []
    private var rowSetsScale: [Bool] = []
    private var rowKind: [SegmentKind] = []
    private var rowPlace: [Int] = []
    private var segmentRow: [Int64: Int] = [:]
    private var vectorSegments: [Int64: [Int64]] = [:]
    private var segmentFile: [Int64: Int64] = [:]
    private var fileSegments: [Int64: [Int64]] = [:]
    private var fileKind: [Int64: FileKind] = [:]
    private var filePath: [Int64: String] = [:]
    private var filePages: [Int64: Int] = [:]
    private var metadataGeneration: Int64?
    private var vectorGeneration: Int64?
    private var matrixSource: String?
    public private(set) var vectorSource: String?
    public private(set) var vectorsLoaded = false
    public private(set) var lastQueryUsedMeaning = false
    /// Diagnostics used by regression/performance tests: unchanged and metadata-only refreshes read no vector blobs.
    private(set) var refreshedVectorRows = 0
    private(set) var refreshWasFull = false

    public var vectorCount: Int { rowFile.count }
    public var isCode: Bool { store.file.lastPathComponent == IndexStore.codeFile }

    public init(store: IndexStore, loadVectors: Bool = true) throws {
        self.store = store
        try store.db.readTransaction { try update(loadVectors: loadVectors) }
    }

    /// Force a complete snapshot, for recovery or an explicit rebuild. Ordinary indexing calls use `refresh()`.
    public func reload() throws {
        try store.db.readTransaction {
            metadataGeneration = nil
            vectorGeneration = nil
            try update(loadVectors: true)
        }
    }

    /// Observe committed changes without reading unchanged vector blobs. The writer never waits for this read snapshot.
    public func refresh() throws {
        try store.db.readTransaction { try update(loadVectors: vectorsLoaded) }
    }

    public func releaseVectors() {
        matrix = nil
        rowFile = []; rowSegment = []; rowModality = []; rowSetsScale = []; rowKind = []; rowPlace = []
        segmentRow = [:]
        vectorSegments = [:]
        vectorsLoaded = false
        vectorGeneration = nil
        matrixSource = nil
    }

    private func update(loadVectors: Bool, refreshLoaded: Bool = true) throws {
        refreshedVectorRows = 0
        refreshWasFull = false
        let generation = try store.searchGeneration()
        let oldMetadata = metadataGeneration
        let fullMetadata = oldMetadata == nil || oldMetadata! < generation.floor || oldMetadata! > generation.current
        var changed: [(file: Int64, vectors: Int64)] = []
        if fullMetadata || oldMetadata != generation.current {
            if fullMetadata {
                fileKind.removeAll(keepingCapacity: true)
                filePath.removeAll(keepingCapacity: true)
                filePages.removeAll(keepingCapacity: true)
                segmentFile.removeAll(keepingCapacity: true)
                fileSegments.removeAll(keepingCapacity: true)
                try readFiles()
                try readSegmentFiles()
            } else {
                try store.db.query("SELECT file, vector_generation FROM search_changes WHERE generation > ?",
                                   [.int(oldMetadata!)]) { changed.append(($0.int(0), $0.int(1))) }
                for change in changed {
                    fileKind[change.file] = nil; filePath[change.file] = nil; filePages[change.file] = nil
                    if let segments = fileSegments.removeValue(forKey: change.file) {
                        for id in segments { segmentFile[id] = nil }
                    }
                }
                try batches(changed.map(\.file)) { ids in
                    try readFiles(whereSQL: " WHERE id IN (\(ids))")
                    try readSegmentFiles(whereSQL: " WHERE file IN (\(ids))")
                }
            }
            vectorSource = try store.meta("vector_source")
            metadataGeneration = generation.current
        }
        guard loadVectors || (refreshLoaded && vectorsLoaded) else { return }
        do {
            if !vectorsLoaded || vectorGeneration == nil || vectorGeneration! < generation.floor || matrixSource != vectorSource || fullMetadata {
                try loadAllVectors()
                refreshWasFull = true
            } else if vectorGeneration != generation.current {
                // Metadata may have been refreshed by a keyword query while vectors were released. If it advanced
                // independently, ask the journal from the vector snapshot, rather than losing those intervening edits.
                if oldMetadata != vectorGeneration {
                    changed = []
                    try store.db.query("SELECT file, vector_generation FROM search_changes WHERE generation > ?",
                                       [.int(vectorGeneration!)]) { changed.append(($0.int(0), $0.int(1))) }
                }
                let vectorFiles = changed.filter { $0.vectors > vectorGeneration! }.map(\.file)
                for file in vectorFiles { removeVectors(of: file) }
                try batches(vectorFiles) { ids in try readVectors(whereSQL: " AND file IN (\(ids))") }
                for change in changed {
                    for id in fileSegments[change.file] ?? [] {
                        if let row = segmentRow[id] { rowSetsScale[row] = setsScale(file: change.file, kind: rowKind[row], place: rowPlace[row]) }
                    }
                }
            }
            vectorsLoaded = true
            vectorGeneration = generation.current
            matrixSource = vectorSource
        } catch {
            // A partial refresh must never become a searchable matrix. The next request retries a full snapshot.
            releaseVectors()
            metadataGeneration = nil
            throw error
        }
    }

    private func batches(_ files: [Int64], _ body: (String) throws -> Void) rethrows {
        for start in stride(from: 0, to: files.count, by: 500) {
            try body(files[start..<min(start + 500, files.count)].map(String.init).joined(separator: ","))
        }
    }

    private func readFiles(whereSQL: String = "") throws {
        try store.db.query("SELECT id, path, kind, CAST(json_extract(info, '$.pages') AS INTEGER) FROM files\(whereSQL)") {
            let id = $0.int(0)
            filePath[id] = $0.text(1) ?? ""
            fileKind[id] = FileKind(rawValue: $0.text(2) ?? "") ?? .doc
            filePages[id] = Int($0.int(3))
        }
    }

    private func readSegmentFiles(whereSQL: String = "") throws {
        // The covering indexes contain these integers without touching pages holding vector blobs.
        let index = whereSQL.isEmpty ? "segments_search" : "segments_file"
        try store.db.query("SELECT id, file FROM segments INDEXED BY \(index)\(whereSQL)") {
            let id = $0.int(0), file = $0.int(1)
            segmentFile[id] = file
            fileSegments[file, default: []].append(id)
        }
    }

    private func setsScale(file: Int64, kind: SegmentKind, place: Int) -> Bool {
        let steps = IndexOptions()
        return !(fileKind[file] == .pdf
            ? kind != .chunk && filePages[file, default: 0] > steps.bigPDFPages && place > steps.pdfStep
            : kind == .chunk && place > steps.docStep)
    }

    private func loadAllVectors() throws {
        releaseVectors()
        var rows = 0
        try store.db.query("SELECT COUNT(*) FROM segments WHERE vec IS NOT NULL") { rows = Int($0.int(0)) }
        try ensureCapacity(rows)
        rowFile.reserveCapacity(rows); rowSegment.reserveCapacity(rows); rowModality.reserveCapacity(rows)
        rowSetsScale.reserveCapacity(rows); rowKind.reserveCapacity(rows); rowPlace.reserveCapacity(rows)
        segmentRow.reserveCapacity(rows)
        try readVectors()
    }

    private func ensureCapacity(_ rows: Int) throws {
        guard rows > (matrix?.rows ?? 0) else { return }
        let spare = max(256, rows / 4)
        guard rows <= Int.max - spare else { throw Database.Failure(message: "search vector capacity is too large") }
        let capacity = max(rows + spare, (matrix?.rows ?? 0) + max(256, (matrix?.rows ?? 0) / 2))
        guard let next = VectorStorage(rows: capacity) else { throw Database.Failure(message: "not enough memory to load search vectors") }
        if let matrix, !rowFile.isEmpty { next.halves.update(from: matrix.halves, count: rowFile.count * Vectors.dimension) }
        matrix = next
    }

    private func readVectors(whereSQL: String = "") throws {
        try store.db.query("SELECT id, file, modality, vec, kind, loc FROM segments WHERE vec IS NOT NULL\(whereSQL) ORDER BY id") { row in
            let bytes = Vectors.dimension * MemoryLayout<Float16>.stride
            try row.withBlob(3) { blob in
                guard blob.count == bytes else { return }
                try ensureCapacity(rowFile.count + 1)
                let index = rowFile.count, file = row.int(1), id = row.int(0)
                UnsafeMutableRawBufferPointer(start: matrix!.halves + index * Vectors.dimension, count: bytes).copyMemory(from: blob)
                let kind = SegmentKind(rawValue: row.text(4) ?? "") ?? .chunk
                let place = row.isNull(5) ? 0 : Int(row.double(5))
                rowFile.append(file); rowSegment.append(id)
                rowModality.append(Modality(rawValue: row.text(2) ?? "") ?? .none)
                rowKind.append(kind); rowPlace.append(place)
                rowSetsScale.append(setsScale(file: file, kind: kind, place: place))
                segmentRow[id] = index
                vectorSegments[file, default: []].append(id)
                refreshedVectorRows += 1
            }
        }
    }

    private func removeVectors(of file: Int64) {
        for id in vectorSegments.removeValue(forKey: file) ?? [] { if let row = segmentRow[id] { removeVector(at: row) } }
    }

    private func removeVector(at row: Int) {
        let last = rowFile.count - 1
        segmentRow[rowSegment[row]] = nil
        if row != last {
            matrix!.halves.advanced(by: row * Vectors.dimension).update(from: matrix!.halves + last * Vectors.dimension, count: Vectors.dimension)
            rowFile[row] = rowFile[last]; rowSegment[row] = rowSegment[last]; rowModality[row] = rowModality[last]
            rowSetsScale[row] = rowSetsScale[last]; rowKind[row] = rowKind[last]; rowPlace[row] = rowPlace[last]
            segmentRow[rowSegment[row]] = row
        }
        rowFile.removeLast(); rowSegment.removeLast(); rowModality.removeLast()
        rowSetsScale.removeLast(); rowKind.removeLast(); rowPlace.removeLast()
    }

    /// How much finding the query's words counts against meaning (`search`). Code's words count for less: they're
    /// everywhere in code ("app", "running", "location"), and a stretch that shares a few of them beat the one that
    /// does what the query says (2026-10-09, the real-code eval of 27 queries over DigUp, Sparkle and llama.cpp: 18 → 20
    /// found first, the top 5 unchanged; the synthetic code eval 40 → 41 of 41; 1.5 changed nothing, 0.5 lost the top 5).
    public static let wordWeight = 2.0
    public static let codeWordWeight = 1.0

    /// Source-aware search. Reloading and validation share the same committed snapshot.
    /// `eligible` is a cheap scope/kind rule. `available` can check the filesystem: only ranked candidates are checked,
    /// and missing files are replaced before the result limit is applied.
    public func search(_ text: String, query: QueryVector?, kinds: Set<FileKind>? = nil, limit: Int = 20,
                       zGate: Double = 2.0, wordWeight: Double? = nil, prefixLast: Bool = false,
                       eligible: ((String, FileKind) -> Bool)? = nil,
                       available: ((String) -> Bool)? = nil) throws -> [SearchHit] {
        try store.db.readTransaction {
            try update(loadVectors: false, refreshLoaded: false)
            let values = query.flatMap { $0.source == vectorSource ? $0.values : nil }
            if values != nil { try update(loadVectors: true) }
            else if matrixSource != vectorSource { releaseVectors() }
            return try searchSnapshot(text, queryVector: values, kinds: kinds, limit: limit, zGate: zGate,
                                      wordWeight: wordWeight, prefixLast: prefixLast, eligible: eligible, available: available)
        }
    }

    /// Compatibility for callers that already ensure source compatibility. New hosts should use `query:`.
    public func search(_ text: String, queryVector: [Float]?, kinds: Set<FileKind>? = nil, limit: Int = 20,
                       zGate: Double = 2.0, wordWeight: Double? = nil, prefixLast: Bool = false,
                       eligible: ((String, FileKind) -> Bool)? = nil,
                       available: ((String) -> Bool)? = nil) throws -> [SearchHit] {
        try store.db.readTransaction {
            try update(loadVectors: queryVector != nil)
            return try searchSnapshot(text, queryVector: queryVector, kinds: kinds, limit: limit, zGate: zGate,
                                      wordWeight: wordWeight, prefixLast: prefixLast, eligible: eligible, available: available)
        }
    }

    private func searchSnapshot(_ text: String, queryVector: [Float]?, kinds: Set<FileKind>?, limit: Int,
                                zGate: Double, wordWeight: Double?, prefixLast: Bool,
                                eligible: ((String, FileKind) -> Bool)?,
                                available: ((String) -> Bool)?) throws -> [SearchHit] {
        lastQueryUsedMeaning = false
        guard limit > 0 else { return [] }
        let wordWeight = wordWeight ?? (isCode ? Self.codeWordWeight : Self.wordWeight)
        var eligibility: [Int64: Bool] = [:], availability: [Int64: Bool] = [:]
        func allowed(_ file: Int64) -> Bool {
            if let known = eligibility[file] { return known }
            guard let kind = fileKind[file], let path = filePath[file] else { eligibility[file] = false; return false }
            let value = (kinds == nil || kinds!.contains(kind)) && (eligible?(path, kind) ?? true)
            eligibility[file] = value
            return value
        }
        func isAvailable(_ file: Int64) -> Bool {
            if let known = availability[file] { return known }
            let value = filePath[file].map { available?($0) ?? true } ?? false
            availability[file] = value
            return value
        }
        lastQueryUsedMeaning = queryVector?.count == Vectors.dimension && !rowFile.isEmpty

        // Meaning: score every vector on this query's scale (`meaning`), keep each file's best segment.
        var best: [Int64: (z: Double, cosine: Double, row: Int)] = [:]
        if let query = queryVector, query.count == Vectors.dimension, !rowFile.isEmpty {
            let scores = score(query)
            let meaning = Self.meaning(scores, rowModality, setsScale: rowSetsScale)
            for row in 0..<scores.count {
                let z = meaning[row]
                let previous = best[rowFile[row]]
                if z > (previous?.z ?? -.infinity)
                    || (z == previous?.z && rowSegment[row] < rowSegment[previous!.row]) {
                    best[rowFile[row]] = (z, Double(scores[row]), row)
                }
            }
        }

        // Words: FTS5 with Porter stemming over file names, folder names, OCR, page and document text. A name from code
        // ("quantize_row_q8_0_ref") is matched as one phrase, as it's written.
        let terms = Self.terms(text)
        let identifier = isCode ? CodeLookup.identifier(text) : nil
        var words: [(file: Int64, segment: Int64)] = []
        var coverage: [Int64: Double] = [:]   // share of the query's words found anywhere in the file
        var patterns = identifier.map { [CodeLookup.phrase($0)] } ?? Self.patterns(terms, prefixLast: prefixLast)
        // A word that's in no file as typed matches as the start of longer words, as the last word does while it's
        // being typed: "grok" finds "Grok4" and "Grokipedia" (stemming only covers endings, as in "grokking").
        // Otherwise a file the panel showed while you typed dropped out once you stopped. A word that is in the index
        // as typed stays whole, so "cat" doesn't bring in "category"; so does a word of two letters, the start of too
        // many words to stand for one.
        if identifier == nil {
            for index in terms.indices where terms[index].count >= 3 && !patterns[index].hasSuffix("*") {
                if try !isIndexed(patterns[index]) { patterns[index] += "*" }
            }
        }
        if !patterns.isEmpty {
            var seen = Set<Int64>()
            // Rank cheap row IDs first. A long file cannot consume a segment cap, and excluded files do not consume
            // the distinct-file budget. Snippets are read only for the final hits, after fusion.
            try store.db.queryUntil("""
                SELECT rowid FROM fts WHERE fts MATCH ? AND rank MATCH 'bm25(3.0, 1.0)' ORDER BY rank
                """, [.text(patterns.joined(separator: " OR "))]) { row in
                guard let file = segmentFile[row.int(0)], seen.insert(file).inserted, allowed(file), isAvailable(file) else { return true }
                words.append((file, row.int(0)))
                return words.count < max(100, limit)
            }
            if !words.isEmpty {
                for pattern in patterns {
                    var remaining = Set(words.map(\.file))
                    try store.db.queryUntil("SELECT rowid FROM fts WHERE fts MATCH ?", [.text(pattern)]) { row in
                        if let file = segmentFile[row.int(0)], remaining.remove(file) != nil {
                            coverage[file, default: 0] += 1 / Double(patterns.count)
                        }
                        return !remaining.isEmpty
                    }
                }
            }
        }

        // A file qualifies by standing out in meaning, or by containing at least half of the query's words.
        // Score: meaning z + a bonus that grows with word coverage, + 1 for the kind the query asks for.
        // One common word can't beat a strong meaning match; all the words of an exact lookup usually do.
        // (This beat reciprocal-rank fusion on both evals, 2026-10-07: R@1 0.88 vs 0.73 synthetic, 0.86 vs 0.82 real.)
        let lookup = Self.isLookup(terms) || identifier != nil
        let (meaningWeight, wordsWeight) = lookup ? (0.5, wordWeight * 2) : (1, wordWeight)
        let hinted = Self.kindHints(text)
        var candidates = Set(best.filter { $0.value.z >= zGate && allowed($0.key) }.keys)
        for (file, share) in coverage where share >= 0.5 { candidates.insert(file) }
        var scored: [Int64: Double] = [:]
        for file in candidates {
            var score = meaningWeight * max(best[file]?.z ?? 0, 0) + wordsWeight * pow(coverage[file] ?? 0, 1.5)
            if let kind = fileKind[file], hinted.contains(kind) { score += 1 }
            scored[file] = score
        }

        let wordRank = Dictionary(words.enumerated().map { ($0.element.file, ($0.offset + 1, $0.element)) },
                                  uniquingKeysWith: { first, _ in first })
        var hits: [SearchHit] = []
        for (file, score) in scored.sorted(by: {
            if $0.value != $1.value { return $0.value > $1.value }
            let left = wordRank[$0.key]?.0 ?? Int.max, right = wordRank[$1.key]?.0 ?? Int.max
            return left != right ? left < right : $0.key < $1.key
        }) {
            guard hits.count < limit else { break }
            guard isAvailable(file) else { continue }
            let rank = hits.count
            let semantic = best[file]
            let keyword = wordRank[file]
            // Point at the best meaning segment if it stands out; else at the segment the words matched.
            let useMeaning = semantic.map { $0.z >= zGate || keyword == nil } ?? false
            guard var segmentID = useMeaning ? semantic.map({ rowSegment[$0.row] }) : keyword?.1.segment else { continue }
            var focus: Double?
            if isCode {
                // Where a name is defined is looked for in the first 10 results only: a name used all over a big repo
                // (ggml_tensor) is in hundreds of stretches of every file that has it (2026-10-09, llama.cpp and two
                // more repos: 560 → 100 ms a search; the others take 10–50 ms).
                (segmentID, focus) = try codePlace(file: file, segment: segmentID,
                                                   identifier: rank < 10 ? identifier : nil, query: text, terms: terms,
                                                   wordsHere: keyword?.1.segment == segmentID || identifier != nil)
            }
            var path = "", kind = FileKind.doc, modified = 0.0, size: Int64 = 0, info: [String: String] = [:]
            try store.db.query("SELECT path, kind, mtime, size, info FROM files WHERE id = ?", [.int(file)]) {
                path = $0.text(0) ?? ""
                kind = FileKind(rawValue: $0.text(1) ?? "") ?? .doc
                modified = $0.double(2)
                size = $0.int(3)
                if let json = $0.text(4)?.data(using: .utf8) {
                    info = (try? JSONSerialization.jsonObject(with: json) as? [String: String]) ?? [:]
                }
            }
            var keywordSnippet: String?
            if let keyword {
                try store.db.query("SELECT snippet(fts, 1, '«', '»', '…', 12), original FROM fts WHERE fts MATCH ? AND rowid = ?",
                                   [.text(patterns.joined(separator: " OR ")), .int(keyword.1.segment)]) {
                    keywordSnippet = $0.text(1).flatMap { SearchText.snippet($0, terms: terms) } ?? $0.text(0)
                }
            }
            var segment = SegmentKind.name, loc: Double?, locEnd: Double?, storedExcerpt: String?
            var foundSegment = false
            try store.db.query("SELECT kind, loc, loc_end, excerpt FROM segments WHERE id = ? AND file = ?", [.int(segmentID), .int(file)]) {
                foundSegment = true
                segment = SegmentKind(rawValue: $0.text(0) ?? "") ?? .name
                loc = $0.isNull(1) ? nil : $0.double(1)
                locEnd = $0.isNull(2) ? nil : $0.double(2)
                storedExcerpt = $0.text(3)
            }
            guard foundSegment, !path.isEmpty else { continue }
            // Quote the matched words only when they come from the segment we point at, so a PDF hit on page 5
            // never shows page 2's words. A segment with no place and no text of its own (a screenshot's image
            // vector) can borrow them from its file's OCR text, which describes the same picture.
            var snippet = keyword.flatMap { $0.1.segment == segmentID ? keywordSnippet : nil }
                .flatMap { $0.contains("«") ? excerpt($0, limit: 400) : nil }
            if snippet == nil, storedExcerpt == nil, loc == nil, let match = keyword?.1,
               let text = keywordSnippet, text.contains("«") {
                var matchedKind: String?
                try store.db.query("SELECT kind FROM segments WHERE id = ?", [.int(match.segment)]) {
                    matchedKind = $0.text(0)
                }
                if matchedKind != SegmentKind.name.rawValue { snippet = excerpt(text, limit: 400) }
            }
            hits.append(SearchHit(path: path, kind: kind, score: score, z: semantic?.z, cosine: semantic?.cosine,
                                  keywordRank: keyword?.0, segment: segment, segmentID: segmentID, loc: loc,
                                  locEnd: locEnd,
                                  excerpt: snippet ?? storedExcerpt, modified: modified, size: size, info: info,
                                  focus: focus))
        }
        return hits
    }

    /// Code: the stretch to point at, and the line in it to open at. A name looked up points at the stretch that
    /// defines it, when one does (not the ones that call it). Otherwise the line is the first with the query's words,
    /// when they matched in this stretch; a match by meaning alone opens at the stretch's first line.
    private func codePlace(file: Int64, segment: Int64, identifier: [String]?, query: String, terms: [String],
                           wordsHere: Bool) throws -> (Int64, Double?) {
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "()", with: "")
        if let identifier {
            var best: (segment: Int64, line: Int, strength: Int)?
            try store.db.query("""
                SELECT s.id, s.loc, coalesce(fts.original, fts.body) FROM fts JOIN segments s ON s.id = fts.rowid
                WHERE fts MATCH ? AND s.file = ? ORDER BY s.loc LIMIT 300
                """, [.text(CodeLookup.phrase(identifier)), .int(file)]) { row in
                guard best?.strength ?? 0 < 2, let text = row.text(2),
                      let found = CodeLookup.definition(of: name, in: text, first: Int(row.double(1))) else { return }
                if found.strength > (best?.strength ?? 0) { best = (row.int(0), found.line, found.strength) }
            }
            if let best { return (best.segment, Double(best.line)) }
        }
        guard wordsHere || identifier != nil, let text = try text(ofSegment: segment) else { return (segment, nil) }
        var first = 1
        try store.db.query("SELECT loc FROM segments WHERE id = ?", [.int(segment)]) { first = Int($0.double(0)) }
        let words = identifier == nil ? terms : [name.lowercased()]
        return (segment, CodeLookup.firstLine(with: words, in: text, first: first).map(Double.init))
    }

    /// Codes and IDs ("K7Q2LM", "TRX50") and long numbers ("4815162342": an order, a phone number) mean nothing to an
    /// embedding but everything to keyword search: a query made of them weighs words double and meaning half. Numbers
    /// count since 2026-10-09, when text of digits lost its vectors (`SearchText.hasWords`): a number in a data dump fell
    /// below unrelated meaning matches.
    static func isLookup(_ terms: [String]) -> Bool {
        !terms.isEmpty && terms.allSatisfy {
            $0.contains(where: \.isNumber) && ($0.contains(where: \.isLetter) || $0.count >= 4)
        }
    }

    /// How many of `hits` (best first) are strong: scoring at least `ratio` × the top hit. The rest pass the gates but
    /// trail far behind, and the app folds them under "weaker matches". On both evals (2026-10-07), 0.5 cut the list
    /// from 26.2 to 5.7 results per query and never folded an expected answer.
    public static func strongCount(_ hits: [SearchHit], ratio: Double = 0.5) -> Int {
        guard let top = hits.first?.score, top > 0 else { return hits.count }
        return hits.prefix { $0.score >= top * ratio }.count
    }

    /// Cosine similarity of `query` with every stored vector (all are L2-normalized): a matrix-vector product, done a
    /// block of rows at a time, each block turned into float32 first.
    private func score(_ query: [Float]) -> [Float] {
        let rows = rowFile.count
        var scores = [Float](repeating: 0, count: rows)
        guard let matrix, rows > 0 else { return scores }
        query.withUnsafeBufferPointer { query in
            scores.withUnsafeMutableBufferPointer { scores in
                var row = 0
                while row < rows {
                    let count = min(VectorStorage.blockRows, rows - row)
                    Vectors.floats(fromHalf: matrix.halves + row * Vectors.dimension, count: count * Vectors.dimension,
                                   to: matrix.block)
                    // (count × 768) · (768 × 1)
                    Vectors.scores(of: matrix.block, count: count, query: query.baseAddress!,
                                   into: scores.baseAddress! + row)
                    row += count
                }
            }
        }
        return scores
    }

    /// This query's meaning scores: each vector's cosine similarity minus the average of its modality (text, image and
    /// audio vectors can sit at slightly different levels for the same query), in standard deviations of all of them
    /// together. Within a modality that's the model's own order. Scaling each modality by its own deviation instead
    /// inflated the narrow ones and buried PDF pages under pictures (2026-10-08, on the three evals: 91 → 94 of 105
    /// queries with the right answer first).
    ///
    /// The scale (the averages and the deviation) comes from the vectors in `setsScale` (all by default): `search` leaves
    /// out the later pages of long files, which are scored on it but don't move it. A book's hundreds of pages pulled the
    /// text average down for every query, and documents rose over screenshots everywhere (2026-10-09, the testbed's long
    /// files finished: real eval 24 → 22 of 26 first; 24 with the scale kept).
    static func meaning(_ scores: [Float], _ modality: [Modality], setsScale: [Bool]? = nil) -> [Double] {
        let means = modalityMeans(scores, modality, setsScale: setsScale)
        let byModality = SIMD4(means[.none, default: 0], means[.text, default: 0],
                              means[.image, default: 0], means[.audio, default: 0])
        // The distribution is unchanged; fixed slots avoid hashing an enum for every scored vector.
        let centered = scores.indices.map { Double(scores[$0]) - byModality[modalityIndex(modality[$0])] }
        var count = 0.0, sum = 0.0
        for row in centered.indices where setsScale?[row] ?? true {
            count += 1
            sum += centered[row]
        }
        let mean = sum / max(count, 1)
        var squares = 0.0
        for row in centered.indices where setsScale?[row] ?? true {
            squares += (centered[row] - mean) * (centered[row] - mean)
        }
        let deviation = max((squares / max(count, 1)).squareRoot(), 0.02)
        return centered.map { ($0 - mean) / deviation }
    }

    /// The average score of each modality for this query. Small groups (< 20 vectors) take the average of all.
    static func modalityMeans(_ scores: [Float], _ modality: [Modality], setsScale: [Bool]? = nil) -> [Modality: Double] {
        var sum = SIMD4<Double>.zero, count = SIMD4<Double>.zero
        for row in scores.indices where setsScale?[row] ?? true {
            let index = modalityIndex(modality[row])
            sum[index] += Double(scores[row])
            count[index] += 1
        }
        let all = sum.sum() / max(count.sum(), 1)
        var out: [Modality: Double] = [:]
        for modality in Modality.allCases {
            let index = modalityIndex(modality)
            if count[index] >= 20 {
                out[modality] = sum[index] / count[index]
            } else {
                out[modality] = all
            }
        }
        return out
    }

    private static func modalityIndex(_ modality: Modality) -> Int {
        switch modality { case .none: 0; case .text: 1; case .image: 2; case .audio: 3 }
    }

    /// The text of a page, a document's passage or a screenshot's OCR, as it's written: the preview shows the part of a
    /// document that matched.
    public func text(ofSegment id: Int64) throws -> String? {
        var text: String?
        try store.db.query("SELECT coalesce(original, body) FROM fts WHERE rowid = ?", [.int(id)]) { text = $0.text(0) }
        return text
    }

    static let stopwords: Set<String> = [
        "a", "an", "the", "of", "in", "on", "at", "to", "for", "with", "and", "or", "my", "me", "that", "this",
        "these", "those", "from", "about", "where", "what", "which", "who", "when", "is", "was", "are", "were", "be",
        "it", "its", "some", "any", "find", "show", "file", "files", "photo", "photos", "picture", "image", "images",
        "screenshot", "screenshots", "video", "videos", "pdf", "document", "documents", "recording",
        // Bengali and Arabic (normalized, as `terms` sees them)
        "এবং", "ও", "এই", "সেই", "একটি", "আমার", "থেকে", "জন্য", "সাথে", "মধ্যে", "কোথায়", "কোন", "কী", "কি", "যে",
        "ছবি", "স্ক্রিনশট", "ভিডিও", "ফাইল", "পিডিএফ",
        "في", "من", "على", "الى", "عن", "مع", "هذا", "هذه", "ذلك", "التي", "الذي", "اين", "ما",
        "صورة", "صور", "لقطة", "شاشة", "فيديو", "ملف", "مستند",
    ]

    /// The content words of a query, normalized as keyword search keeps its text (`SearchText`). Kind words
    /// ("screenshot", "video") and stopwords are dropped: they describe what to look for, not what's in it. Words of
    /// two letters or more count; a Bengali letter with its vowel sign ("মা") is two.
    public static func terms(_ text: String) -> [String] {
        var seen = Set<String>()
        return SearchText.normalized(text).lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.unicodeScalars.count >= 2 && !stopwords.contains($0) && seen.insert($0).inserted }
    }

    /// FTS5 patterns for the query's words: quoted, and as prefixes for the last word while it's being typed and for
    /// words of languages that attach endings (`SearchText.inflects`). `search` makes a word that's in no file a
    /// prefix too.
    static func patterns(_ terms: [String], prefixLast: Bool) -> [String] {
        terms.enumerated().map { index, term in
            let prefix = (prefixLast && index == terms.count - 1) || SearchText.inflects(term)
            return "\"\(term)\"" + (prefix ? "*" : "")
        }
    }

    /// Whether keyword search finds `pattern` in any file.
    private func isIndexed(_ pattern: String) throws -> Bool {
        var found = false
        try store.db.query("SELECT 1 FROM fts WHERE fts MATCH ? LIMIT 1", [.text(pattern)]) { _ in found = true }
        return found
    }

    /// The query's words as an FTS5 OR-query.
    public static func ftsQuery(_ text: String, prefixLast: Bool = false) -> String? {
        let words = terms(text)
        guard !words.isEmpty else { return nil }
        return patterns(words, prefixLast: prefixLast).joined(separator: " OR ")
    }

    static let kindWords: [String: FileKind] = [
        "screenshot": .screenshot, "screenshots": .screenshot, "photo": .image, "photos": .image, "picture": .image,
        "pictures": .image, "image": .image, "images": .image, "pdf": .pdf, "pdfs": .pdf, "paper": .pdf,
        "papers": .pdf, "document": .doc, "documents": .doc, "note": .doc, "notes": .doc, "video": .video,
        "videos": .video, "clip": .video, "movie": .video, "audio": .audio, "song": .audio, "podcast": .audio,
        "voice": .audio, "sound": .audio,
        "স্ক্রিনশট": .screenshot, "ছবি": .image, "পিডিএফ": .pdf, "নোট": .doc, "ভিডিও": .video, "অডিও": .audio,
        "গান": .audio, "রেকর্ডিং": .audio,
        "لقطة": .screenshot, "صورة": .image, "صور": .image, "مستند": .doc, "ملاحظات": .doc, "فيديو": .video,
        "مقطع": .video, "صوت": .audio, "تسجيل": .audio, "اغنية": .audio,
    ]

    /// Kinds the query asks for ("…in a video", "screenshot of…", "ভিডিওতে"): a soft boost, not a filter. Bengali
    /// attaches case endings, so a Bengali kind word also counts at the start of a longer word.
    static func kindHints(_ text: String) -> Set<FileKind> {
        Set(SearchText.normalized(text).lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .compactMap { word in
                kindWords[word] ?? kindWords.first { key, _ in
                    SearchText.inflects(key) && key.unicodeScalars.count >= 3 && word.hasPrefix(key)
                }?.value
            })
    }
}
