import Foundation

/// Archive ZIP sans compression (méthode « stored ») : les photos JPEG / HEIC sont déjà
/// compressées. Lisible par l'app Fichiers d'iOS, l'Explorateur Windows, le Finder.
/// Limite : fichiers et archive de moins de 4 Go (pas de ZIP64).
public final class ZipWriter {
    private let handle: FileHandle
    private var offset: UInt64 = 0
    private var central = Data()
    private var count = 0
    private var names = Set<String>()

    public init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    private func write(_ d: Data) throws {
        try handle.write(contentsOf: d)
        offset += UInt64(d.count)
    }

    private static func dosTime(_ date: Date) -> (UInt16, UInt16) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        // Calcul en étapes : une seule expression dépasse le temps de vérification de types de Swift 6.1.
        let hour: Int = c.hour ?? 0, minute: Int = c.minute ?? 0, second: Int = c.second ?? 0
        let year: Int = max(0, (c.year ?? 1980) - 1980), month: Int = c.month ?? 1, day: Int = c.day ?? 1
        let time: Int = (hour << 11) | (minute << 5) | (second / 2)
        let date: Int = (year << 9) | (month << 5) | day
        return (UInt16(truncatingIfNeeded: time), UInt16(truncatingIfNeeded: date))
    }

    public func add(name: String, data: Data, date: Date = Date()) throws {
        try add(name: name, size: UInt64(data.count), crc: CRC32.of(data), date: date) { try self.write(data) }
    }

    /// Ajoute un fichier du disque, lu par blocs (deux lectures : CRC puis copie).
    public func add(name: String, file: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let date = attrs[.modificationDate] as? Date ?? Date()
        var crc = CRC32()
        try Self.chunks(file) { crc.update($0) }
        try add(name: name, size: size, crc: crc.checksum, date: date) {
            try Self.chunks(file) { try self.write($0) }
        }
    }

    static func chunks(_ url: URL, _ body: (Data) throws -> Void) throws {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        while let d = try fh.read(upToCount: 1 << 20), !d.isEmpty { try body(d) }
    }

    private func add(name: String, size: UInt64, crc: UInt32, date: Date, body: () throws -> Void) throws {
        guard !names.contains(name) else { throw SQLiteError("Nom en double dans l'archive : \(name)") }
        guard size < 0xFFFF_FFFF, offset < 0xFFFF_FFFF else { throw SQLiteError("Archive de plus de 4 Go : non prise en charge") }
        names.insert(name)
        let nameData = Data(name.utf8)
        let (t, d) = Self.dosTime(date)
        let local = offset
        var h = Data()
        h.le32(0x04034b50); h.le16(20); h.le16(0x0800); h.le16(0); h.le16(t); h.le16(d)
        h.le32(crc); h.le32(UInt32(size)); h.le32(UInt32(size)); h.le16(UInt16(nameData.count)); h.le16(0)
        h.append(nameData)
        try write(h)
        try body()
        var c = Data()
        c.le32(0x02014b50); c.le16(20); c.le16(20); c.le16(0x0800); c.le16(0); c.le16(t); c.le16(d)
        c.le32(crc); c.le32(UInt32(size)); c.le32(UInt32(size)); c.le16(UInt16(nameData.count)); c.le16(0); c.le16(0)
        c.le16(0); c.le16(0); c.le32(0); c.le32(UInt32(local))
        c.append(nameData)
        central.append(c)
        count += 1
    }

    public func finish() throws {
        let start = offset
        try write(central)
        var e = Data()
        e.le32(0x06054b50); e.le16(0); e.le16(0); e.le16(UInt16(count)); e.le16(UInt16(count))
        e.le32(UInt32(central.count)); e.le32(UInt32(start)); e.le16(0)
        try write(e)
        try handle.close()
    }
}

/// Lecture d'une archive ZIP « stored » (celles produites par `ZipWriter`).
public final class ZipReader {
    public struct Entry: Sendable {
        public let name: String
        public let size: UInt64
        public let crc: UInt32
        let method: UInt16
        let localOffset: UInt64
    }

    private let handle: FileHandle
    public private(set) var entries: [Entry] = []

    public init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        let total = try handle.seekToEnd()
        let tailLen = min(total, 65_557)
        try handle.seek(toOffset: total - tailLen)
        let tail = try handle.read(upToCount: Int(tailLen)) ?? Data()
        guard let eocd = Self.lastIndex(of: [0x50, 0x4b, 0x05, 0x06], in: tail) else { throw SQLiteError("Ce fichier n'est pas une archive ZIP.") }
        let n = Int(tail.u16(eocd + 10))
        let cdSize = UInt64(tail.u32(eocd + 12))
        let cdOffset = UInt64(tail.u32(eocd + 16))
        try handle.seek(toOffset: cdOffset)
        let cd = try handle.read(upToCount: Int(cdSize)) ?? Data()
        var p = 0
        for _ in 0..<n {
            guard p + 46 <= cd.count, cd.u32(p) == 0x02014b50 else { throw SQLiteError("Archive ZIP abîmée (répertoire central).") }
            let method = cd.u16(p + 10)
            let crc = cd.u32(p + 16)
            let size = UInt64(cd.u32(p + 24))
            let nameLen = Int(cd.u16(p + 28)), extraLen = Int(cd.u16(p + 30)), commentLen = Int(cd.u16(p + 32))
            let local = UInt64(cd.u32(p + 42))
            let name = String(decoding: cd.subdata(in: (p + 46)..<(p + 46 + nameLen)), as: UTF8.self)
            entries.append(Entry(name: name, size: size, crc: crc, method: method, localOffset: local))
            p += 46 + nameLen + extraLen + commentLen
        }
    }

    deinit { try? handle.close() }

    private static func lastIndex(of sig: [UInt8], in d: Data) -> Int? {
        guard d.count >= 22 else { return nil }
        var i = d.count - 22
        while i >= 0 {
            if d[d.startIndex + i] == sig[0] && d[d.startIndex + i + 1] == sig[1] && d[d.startIndex + i + 2] == sig[2] && d[d.startIndex + i + 3] == sig[3] { return i }
            i -= 1
        }
        return nil
    }

    public func entry(_ name: String) -> Entry? { entries.first { $0.name == name } }

    private func dataStart(_ e: Entry) throws -> UInt64 {
        guard e.method == 0 else { throw SQLiteError("« \(e.name) » est compressé : seules les archives de Photothèque pour iOS sont prises en charge.") }
        try handle.seek(toOffset: e.localOffset)
        let h = try handle.read(upToCount: 30) ?? Data()
        guard h.count == 30, h.u32(0) == 0x04034b50 else { throw SQLiteError("Archive ZIP abîmée (\(e.name)).") }
        return e.localOffset + 30 + UInt64(h.u16(26)) + UInt64(h.u16(28))
    }

    public func read(_ e: Entry) throws -> Data {
        try handle.seek(toOffset: try dataStart(e))
        let d = try handle.read(upToCount: Int(e.size)) ?? Data()
        guard d.count == Int(e.size), CRC32.of(d) == e.crc else { throw SQLiteError("Contrôle CRC en échec : \(e.name)") }
        return d
    }

    /// Extrait une entrée vers un fichier, par blocs, avec contrôle CRC.
    public func extract(_ e: Entry, to url: URL) throws {
        let start = try dataStart(e)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let out = try FileHandle(forWritingTo: url)
        var crc = CRC32()
        var remaining = e.size
        var pos = start
        do {
            while remaining > 0 {
                try handle.seek(toOffset: pos)
                let n = Int(min(remaining, 1 << 20))
                let d = try handle.read(upToCount: n) ?? Data()
                guard d.count == n else { throw SQLiteError("Archive tronquée : \(e.name)") }
                crc.update(d)
                try out.write(contentsOf: d)
                remaining -= UInt64(n); pos += UInt64(n)
            }
            try out.close()
        } catch {
            try? out.close(); try? FileManager.default.removeItem(at: url); throw error
        }
        guard crc.checksum == e.crc else {
            try? FileManager.default.removeItem(at: url)
            throw SQLiteError("Contrôle CRC en échec : \(e.name)")
        }
    }
}

extension Data {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { for i in 0..<4 { append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
    func u16(_ i: Int) -> UInt16 { UInt16(self[startIndex + i]) | UInt16(self[startIndex + i + 1]) << 8 }
    func u32(_ i: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + i + $1]) << (8 * UInt32($1)) } }
}
