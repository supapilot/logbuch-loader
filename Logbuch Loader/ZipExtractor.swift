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
    // Sicherheitsgrenzen gegen manipulierte („ZIP-Bomben") oder versehentlich
    // riesige Archive. Für echte Ausbildungsunterlagen sind alle Werte sehr
    // großzügig – sie greifen nur bei missbräuchlichen Dateien.
    /// Höchstgröße des Archivs selbst (wird komplett in den Speicher gelesen).
    private static let maxArchiveBytes = 1024 * 1024 * 1024          // 1 GB
    /// Höchstzahl der extrahierten PDFs pro Archiv.
    private static let maxEntries = 1000
    /// Höchstgröße einer einzelnen entpackten Datei (begrenzt die Allokation).
    private static let maxEntryBytes = 200 * 1024 * 1024             // 200 MB
    /// Höchstsumme aller entpackten Dateien pro Archiv.
    private static let maxTotalBytes = 1024 * 1024 * 1024            // 1 GB

    /// Extrahiert alle in `zipURL` enthaltenen PDFs nach `dir` und gibt deren
    /// URLs zurück (Original-Dateinamen, ohne innere Pfade).
    static func extractPDFs(from zipURL: URL, into dir: URL) -> [URL] {
        let granted = zipURL.startAccessingSecurityScopedResource()
        defer { if granted { zipURL.stopAccessingSecurityScopedResource() } }
        // Zu große Archive gar nicht erst vollständig in den Speicher laden.
        if let size = try? zipURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > maxArchiveBytes { return [] }
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
        var totalBytes = 0
        for _ in 0..<entryCount {
            // Nicht mehr als maxEntries Dateien extrahieren.
            if result.count >= maxEntries { break }
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

            // Größengrenzen: zu große Einzeldatei überspringen, bei Überschreiten
            // der Gesamtsumme abbrechen (verhindert übermäßige Speicher-Allokation).
            guard uncompSize <= maxEntryBytes, compSize <= maxEntryBytes else { continue }
            if totalBytes + uncompSize > maxTotalBytes { break }

            guard let pdfData = rawEntryData(data, method: method, localOffset: localOffset,
                                             compSize: compSize, uncompSize: uncompSize) else { continue }

            var base = (name as NSString).lastPathComponent
            if base.isEmpty { base = "datei_\(index).pdf" }
            var dest = dir.appendingPathComponent(base)
            if FileManager.default.fileExists(atPath: dest.path) {
                dest = dir.appendingPathComponent("\((base as NSString).deletingPathExtension)_\(index).pdf")
            }
            if (try? pdfData.write(to: dest)) != nil {
                result.append(dest)
                totalBytes += pdfData.count
                index += 1
            }
        }
        return result
    }

    /// Liest ausgewählte Einträge (Name via `matches` gefiltert) als entpackte
    /// Rohdaten in den Speicher – für den XLSX-Reader (XLSX = ZIP aus XML-Teilen).
    static func readEntries(from data: Data, where matches: (String) -> Bool) -> [String: Data] {
        guard let eocd = findEOCD(data) else { return [:] }
        let entryCount = readU16(data, eocd + 10)
        let cdOffset = Int(readU32(data, eocd + 16))

        var out: [String: Data] = [:]
        var p = cdOffset
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
            guard matches(name), uncompSize <= maxEntryBytes, compSize <= maxEntryBytes,
                  compSize != 0xFFFFFFFF, uncompSize != 0xFFFFFFFF, localOffset != 0xFFFFFFFF else { continue }
            if let d = rawEntryData(data, method: method, localOffset: localOffset,
                                    compSize: compSize, uncompSize: uncompSize) {
                out[name] = d
            }
        }
        return out
    }

    // MARK: - ZIP-Parsing

    /// Entpackt die Rohdaten eines Eintrags über seinen lokalen Header (STORE/DEFLATE).
    private static func rawEntryData(_ data: Data, method: Int, localOffset: Int,
                                     compSize: Int, uncompSize: Int) -> Data? {
        guard localOffset + 30 <= data.count, readU32(data, localOffset) == 0x04034b50 else { return nil }
        let lfFnLen = readU16(data, localOffset + 26)
        let lfExtraLen = readU16(data, localOffset + 28)
        let start = localOffset + 30 + lfFnLen + lfExtraLen
        guard start + compSize <= data.count else { return nil }
        let comp = slice(data, start, start + compSize)
        switch method {
        case 0:  return comp                                 // STORE
        case 8:  return inflate(comp, expected: uncompSize)  // DEFLATE
        default: return nil
        }
    }

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
