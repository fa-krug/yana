import Foundation

/// Persists the lightweight article index to disk so a warm cold-start can paint the timeline
/// without any SwiftData fetch. Lives in Caches (a derived artifact; if purged, `ArticleStore`
/// falls back to an anchor-centered DB window). An `actor` so the deferred writes run off the main
/// actor; `loadNow()` is `nonisolated` so the Mac can read it synchronously before its window
/// exists (`ArticleStore.preloadSynchronously()`).
///
/// **The file is a hand-rolled binary format, not a property list.** The Mac shows its window only
/// once this has been read, so decode time is launch time: `PropertyListDecoder` took ~340ms for a
/// 30 000-row index in an optimized build (much more in Debug), this format ~11ms. The repeated
/// strings (feed name, logo hash, author, tag names) go through a string table, which is most of
/// both the size and the speed win. See `SummaryIndexCodec` for the layout.
actor SummaryIndexCache {
    static let shared = SummaryIndexCache()

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            // A unit-test host must not overwrite the real app's cache -- see
            // `TestEnvironment.isolatesProcessStorage`.
            let dir = TestEnvironment.isolatesProcessStorage
                ? FileManager.default.temporaryDirectory
                : FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            // A new name for the new format: a `summary-index.plist` left by an older build is
            // simply never read again rather than misparsed.
            self.fileURL = dir.appendingPathComponent("summary-index.bin")
        }
    }

    /// The cached index, or `nil` when the file is absent or fails to decode. `nil` is a clean
    /// signal to fall back to the DB — never a crash.
    func load() -> [ArticleSummary]? { loadNow() }

    /// `load()` without the actor hop, for a caller that must have the answer before it returns.
    nonisolated func loadNow() -> [ArticleSummary]? {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return nil }
        return SummaryIndexCodec.decode(data)
    }

    /// Replace the cached index. Failures are swallowed: the cache is best-effort and the DB
    /// remains the source of truth.
    func save(_ summaries: [ArticleSummary]) {
        try? SummaryIndexCodec.encode(summaries).write(to: fileURL, options: .atomic)
    }
}

/// The on-disk layout of `SummaryIndexCache`, all integers little-endian:
///
///     "YSIX"  u32 version
///     u32 stringCount, then stringCount × string          -- the string table
///     u32 rowCount,    then rowCount × row
///
///     string = u32 byteCount, UTF-8 bytes
///     row    = string identifier, i64 serverID (Int64.min = nil), string title,
///              u32 feedName, u8 flags (1 starred, 2 read, 4 has logo), [u32 feedLogoHash],
///              u32 author, f64 date, f64 createdAt, u32 tagCount, tagCount × u32 tagName
///
/// where a bare `u32` field is an index into the string table. Every read is bounds-checked, so a
/// truncated or foreign file decodes as `nil` rather than trapping.
enum SummaryIndexCodec {
    private static let magic: [UInt8] = Array("YSIX".utf8)
    private static let version: UInt32 = 1
    private static let noServerID = Int64.min

    static func encode(_ summaries: [ArticleSummary]) -> Data {
        var table = StringTable()
        var body = ByteWriter()
        body.reserve(summaries.count * 96)
        for s in summaries {
            body.string(s.identifier)
            body.int64(s.serverID.map(Int64.init) ?? noServerID)
            body.string(s.title)
            body.uint32(table.index(of: s.feedName))
            let flags: UInt8 = (s.isStarred ? 1 : 0) | (s.isRead ? 2 : 0) | (s.feedLogoHash != nil ? 4 : 0)
            body.byte(flags)
            if let hash = s.feedLogoHash { body.uint32(table.index(of: hash)) }
            body.uint32(table.index(of: s.author))
            body.double(s.date.timeIntervalSinceReferenceDate)
            body.double(s.createdAt.timeIntervalSinceReferenceDate)
            body.uint32(UInt32(s.tagNames.count))
            for tag in s.tagNames { body.uint32(table.index(of: tag)) }
        }

        var out = ByteWriter()
        out.reserve(body.data.count + 64 * table.strings.count + 16)
        out.data.append(contentsOf: magic)
        out.uint32(version)
        out.uint32(UInt32(table.strings.count))
        for string in table.strings { out.string(string) }
        out.uint32(UInt32(summaries.count))
        out.data.append(body.data)
        return out.data
    }

    static func decode(_ data: Data) -> [ArticleSummary]? {
        data.withUnsafeBytes { buffer -> [ArticleSummary]? in
            var r = ByteReader(buffer)
            guard r.bytes(count: magic.count).map(Array.init) == magic,
                  r.uint32() == version,
                  let stringCount = r.count() else { return nil }
            var strings: [String] = []
            strings.reserveCapacity(stringCount)
            for _ in 0..<stringCount {
                guard let s = r.string() else { return nil }
                strings.append(s)
            }
            func interned(_ r: inout ByteReader) -> String? {
                guard let i = r.uint32(), Int(i) < strings.count else { return nil }
                return strings[Int(i)]
            }

            guard let rowCount = r.count() else { return nil }
            var rows: [ArticleSummary] = []
            rows.reserveCapacity(rowCount)
            for _ in 0..<rowCount {
                guard let identifier = r.string(),
                      let serverID = r.int64(),
                      let title = r.string(),
                      let feedName = interned(&r),
                      let flags = r.byte() else { return nil }
                var feedLogoHash: String?
                if flags & 4 != 0 {
                    guard let hash = interned(&r) else { return nil }
                    feedLogoHash = hash
                }
                guard let author = interned(&r),
                      let date = r.double(),
                      let createdAt = r.double(),
                      let tagCount = r.count() else { return nil }
                var tagNames = Set<String>(minimumCapacity: tagCount)
                for _ in 0..<tagCount {
                    guard let tag = interned(&r) else { return nil }
                    tagNames.insert(tag)
                }
                rows.append(ArticleSummary(
                    identifier: identifier,
                    serverID: serverID == noServerID ? nil : Int(serverID),
                    title: title, feedName: feedName, feedLogoHash: feedLogoHash, author: author,
                    date: Date(timeIntervalSinceReferenceDate: date),
                    createdAt: Date(timeIntervalSinceReferenceDate: createdAt),
                    tagNames: tagNames, isStarred: flags & 1 != 0, isRead: flags & 2 != 0
                ))
            }
            return r.isAtEnd ? rows : nil
        }
    }

    private struct StringTable {
        var strings: [String] = []
        private var indices: [String: UInt32] = [:]

        mutating func index(of string: String) -> UInt32 {
            if let i = indices[string] { return i }
            let i = UInt32(strings.count)
            indices[string] = i
            strings.append(string)
            return i
        }
    }

    private struct ByteWriter {
        var data = Data()

        mutating func reserve(_ n: Int) { data.reserveCapacity(n) }
        mutating func byte(_ v: UInt8) { data.append(v) }
        mutating func uint32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        mutating func int64(_ v: Int64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        mutating func double(_ v: Double) { int64(Int64(bitPattern: v.bitPattern)) }
        mutating func string(_ s: String) {
            var s = s
            s.withUTF8 { utf8 in
                uint32(UInt32(utf8.count))
                data.append(contentsOf: utf8)
            }
        }
    }

    private struct ByteReader {
        private let buffer: UnsafeRawBufferPointer
        private var offset = 0

        init(_ buffer: UnsafeRawBufferPointer) { self.buffer = buffer }

        var isAtEnd: Bool { offset == buffer.count }

        mutating func bytes(count: Int) -> UnsafeRawBufferPointer? {
            guard count >= 0, buffer.count - offset >= count else { return nil }
            defer { offset += count }
            return UnsafeRawBufferPointer(rebasing: buffer[offset..<offset + count])
        }

        mutating func byte() -> UInt8? { bytes(count: 1)?[0] }

        mutating func uint32() -> UInt32? {
            bytes(count: 4).map { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        }

        mutating func int64() -> Int64? {
            bytes(count: 8).map { Int64(littleEndian: $0.loadUnaligned(as: Int64.self)) }
        }

        mutating func double() -> Double? { int64().map { Double(bitPattern: UInt64(bitPattern: $0)) } }

        /// A `u32` element count, sanity-bounded by the bytes left so a corrupt count cannot ask
        /// for a multi-gigabyte `reserveCapacity`.
        mutating func count() -> Int? {
            guard let n = uint32().map(Int.init), n <= buffer.count - offset else { return nil }
            return n
        }

        mutating func string() -> String? {
            guard let n = uint32(), let utf8 = bytes(count: Int(n)) else { return nil }
            return String(decoding: utf8, as: UTF8.self)
        }
    }
}
