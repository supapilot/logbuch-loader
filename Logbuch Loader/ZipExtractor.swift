//
//  ZipExtractor.swift
//  Logbuch Loader
//
//  Minimaler, abhängigkeitsfreier ZIP-Leser (sandbox-tauglich): liest das
//  zentrale Verzeichnis und extrahiert die enthaltenen PDFs (STORE/DEFLATE)
//  in ein Zielverzeichnis. Andere Dateitypen werden ignoriert.
//

import Foundation
import Compression

enum ZipExtractor {
    /// Extrahiert alle in `zipURL` enthaltenen PDFs nach `dir` und gibt deren
    /// URLs zurück (Original-Dateinamen, ohne innere Pfade).
    static func extractPDFs(from zipURL: URL, into dir: URL) -> [URL] {
        let granted = zipURL.startAccessingSecurityScopedResource()
        defer { if granted { zipURL.stopAccessingSecurityScopedResource() } }
        guard let raw = try? Data(contentsOf: zipURL) else { return [] }
        return extractPDFs(data: raw, into: dir)
    }

    static func extractPDFs(data: Data, into dir: URL) -> [URL] {
        guard let eocd = findEOCD(data) else { return [] }
        let entryCount = readU16(data, eocd + 10)
        let cdOffset = Int(readU32(data, eocd + 16))

        var result: [URL] = []
        var p = cdOffset
        var index = 0
        for _ in 0..<entryCount {
            guard p + 46 <= data.count, readU32(data, p) == 0x02014b50 else { break }
            let method = readU16(data, p + 10)
            let compSize = Int(readU32(data, p + 20))
            let uncompSize = Int(readU32(data, p + 24))
            let fnLen = readU16(data, p + 28)
            let extraLen = readU16(data, p + 30)
            let commentLen = readU16(data, p + 32)
            let localOffset = Int(readU32(data, p + 42))
            let nameEnd = p + 46 + fnLen
            guard nameEnd <= data.count else { break }
            let name = String(data: slice(data, p + 46, nameEnd), encoding: .utf8) ?? ""
            p = nameEnd + extraLen + commentLen

            // Nur PDFs; Verzeichnisse, versteckte Mac-Metadaten und ZIP64 überspringen.
            let lower = name.lowercased()
            guard !name.hasSuffix("/"), lower.hasSuffix(".pdf"),
                  !name.hasPrefix("__MACOSX"), !((name as NSString).lastPathComponent.hasPrefix("._")),
                  compSize != 0xFFFFFFFF, uncompSize != 0xFFFFFFFF, localOffset != 0xFFFFFFFF else { continue }

            // Datenoffset aus dem lokalen Header.
            guard localOffset + 30 <= data.count, readU32(data, localOffset) == 0x04034b50 else { continue }
            let lfFnLen = readU16(data, localOffset + 26)
            let lfExtraLen = readU16(data, localOffset + 28)
            let start = localOffset + 30 + lfFnLen + lfExtraLen
            guard start + compSize <= data.count else { continue }
            let comp = slice(data, start, start + compSize)

            let pdf: Data?
            switch method {
            case 0: pdf = comp                                  // STORE
            case 8: pdf = inflate(comp, expected: uncompSize)   // DEFLATE
            default: pdf = nil
            }
            guard let pdfData = pdf else { continue }

            var base = (name as NSString).lastPathComponent
            if base.isEmpty { base = "datei_\(index).pdf" }
            var dest = dir.appendingPathComponent(base)
            if FileManager.default.fileExists(atPath: dest.path) {
                dest = dir.appendingPathComponent("\((base as NSString).deletingPathExtension)_\(index).pdf")
            }
            if (try? pdfData.write(to: dest)) != nil {
                result.append(dest)
                index += 1
            }
        }
        return result
    }

    // MARK: - ZIP-Parsing

    private static func findEOCD(_ d: Data) -> Int? {
        let signature: UInt32 = 0x06054b50
        let n = d.count
        guard n >= 22 else { return nil }
        let minStart = max(0, n - 22 - 65535)
        var i = n - 22
        while i >= minStart {
            if readU32(d, i) == signature { return i }
            i -= 1
        }
        return nil
    }

    private static func inflate(_ data: Data, expected: Int) -> Data? {
        guard expected > 0 else { return Data() }
        var out = Data(count: expected)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, expected,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        return written == expected ? out : nil
    }

    /// Teilbereich über 0-basierte Offsets (startIndex-sicher).
    private static func slice(_ d: Data, _ start: Int, _ end: Int) -> Data {
        d.subdata(in: (d.startIndex + start)..<(d.startIndex + end))
    }

    private static func readU16(_ d: Data, _ o: Int) -> Int {
        Int(d[d.startIndex + o]) | (Int(d[d.startIndex + o + 1]) << 8)
    }

    private static func readU32(_ d: Data, _ o: Int) -> UInt32 {
        let s = d.startIndex + o
        return UInt32(d[s]) | (UInt32(d[s + 1]) << 8) | (UInt32(d[s + 2]) << 16) | (UInt32(d[s + 3]) << 24)
    }
}
