//
//  LogbuchService.swift
//  Logbuch Loader
//
//  Kümmert sich um den Login bei logbuch.lotsen.de (WordPress) und
//  liest den Namen des angemeldeten Nutzers aus.
//

import Foundation
import PDFKit

/// Ergebnis eines erfolgreichen Logins.
struct LogbuchUser: Equatable {
    /// Anzeigename, falls er aus der Profilseite gelesen werden konnte –
    /// andernfalls der WordPress-Benutzername.
    let name: String
    /// Der WordPress-Benutzername (aus dem Login-Cookie).
    let username: String
    /// Das Revier des Nutzers, z. B. "Beispiel-Revier (LA1)" – sofern lesbar.
    let revier: String?
    /// Die aktuelle Stufe, z. B. "LA3" – aus dem Revier abgeleitet.
    let stufe: String?
    /// Gesamtanzahl der Fahrten auf der aktuellen Stufe – sofern ermittelbar.
    let fahrtenAnzahl: Int?
}

/// Eine einzelne Fahrt (für den PDF-Download).
struct Drive: Equatable {
    let uniqueID: String
    /// 1-basierte Position in der Fahrtenliste (wie die Seite sie vergibt).
    let driveNumber: Int
    let shipName: String
    /// Datum an Bord im Format "TT.MM.JJJJ".
    let onBoardDate: String
}

/// Eine Fahrt zusammen mit dem fertigen Ziel-Dateinamen.
struct DriveDownload: Equatable {
    let drive: Drive
    let fileName: String
}

enum LogbuchError: LocalizedError {
    case emptyCredentials
    case invalidCredentials
    case network(String)
    case server(Int)
    case unexpected

    var errorDescription: String? {
        switch self {
        case .emptyCredentials:
            return "Bitte Benutzername und Passwort eingeben."
        case .invalidCredentials:
            return "Anmeldung fehlgeschlagen – Benutzername oder Passwort ist falsch."
        case .network(let message):
            return "Netzwerkfehler: \(message)"
        case .server(let code):
            return "Der Server hat unerwartet geantwortet (HTTP \(code))."
        case .unexpected:
            return "Unerwarteter Fehler bei der Anmeldung."
        }
    }
}

/// Führt den WordPress-Login durch und hält die Session-Cookies.
final class LogbuchService {

    // Unveränderliche Konstanten – `nonisolated`, damit sie auch aus den
    // nicht-isolierten Download-Methoden (z. B. downloadPDF) lesbar sind.
    nonisolated static let host = "logbuch.lotsen.de"
    nonisolated static let loginURL = URL(string: "https://logbuch.lotsen.de/wp-login.php")!
    nonisolated static let profileURL = URL(string: "https://logbuch.lotsen.de/profil/?meine-fahrten=show")!

    private let session: URLSession

    /// Aspirant-ID der angemeldeten Sitzung – wird für den Fahrten-Download benötigt.
    private(set) var aspirantID: String?

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        ]
        self.session = URLSession(configuration: config)
    }

    // MARK: - Öffentliche API

    /// Meldet sich an und liefert den Namen des Nutzers zurück.
    func login(username: String, password: String) async throws -> LogbuchUser {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !password.isEmpty else {
            throw LogbuchError.emptyCredentials
        }

        setTestCookie()

        // WordPress erwartet ein POST mit den Feldern aus dem Login-Formular.
        var request = URLRequest(url: Self.loginURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "log": user,
            "pwd": password,
            "wp-submit": "Anmelden",
            "testcookie": "1",
            "redirect_to": Self.profileURL.absoluteString,
        ])

        // Die Antwort folgt dem Redirect und ist bereits die Profilseite – wir
        // verwenden sie direkt (spart einen zweiten Seitenabruf).
        let (profileData, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else { throw LogbuchError.unexpected }
        // wp-login.php meldet ungültige Daten meist mit HTTP 200 + Fehlerseite,
        // gültige Daten mit einem Redirect. Entscheidend ist das Login-Cookie.
        guard (200..<400).contains(http.statusCode) else {
            throw LogbuchError.server(http.statusCode)
        }

        guard let cookieUsername = loggedInUsername() else {
            throw LogbuchError.invalidCredentials
        }

        let html = String(data: profileData, encoding: .utf8)

        // Aspirant-ID aus der Profilseite lesen und die kompakten Nutzerdaten
        // über get_user.php abrufen (schnell, ~1 s, mit Name/Stufe/Fahrtenzahl).
        aspirantID = html.flatMap(Self.extractAspirantID)
        var userData: UserData?
        if let aspirantID {
            userData = try? await fetchUserData(aspirantID: aspirantID)
        }

        // Werte aus get_user.php bevorzugen, sonst auf HTML-Scraping zurückfallen.
        let name = userData?.displayName ?? html.flatMap(Self.extractDisplayName) ?? cookieUsername
        let stufe = userData?.stufe ?? html.flatMap(Self.extractRevier).flatMap(Self.extractStufe)
        let revier = userData?.revier ?? html.flatMap(Self.extractRevier)

        return LogbuchUser(
            name: name,
            username: cookieUsername,
            revier: revier,
            stufe: stufe,
            fahrtenAnzahl: userData?.fahrtenAnzahl
        )
    }

    /// Verwirft die aktuelle Session (Logout).
    func reset() {
        if let storage = session.configuration.httpCookieStorage {
            storage.cookies?.forEach { storage.deleteCookie($0) }
        }
        aspirantID = nil
    }

    // MARK: - get_user.php (kompakte Nutzerdaten)

    /// Ausgewertete Felder aus get_user.php.
    private struct UserData {
        let displayName: String?
        let bruderschaft: String?
        let stufe: String?
        let fahrtenAnzahl: Int?

        /// Revier inkl. Stufe, z. B. "Beispiel-Revier (LA1)".
        var revier: String? {
            guard let bruderschaft else { return nil }
            if let stufe { return "\(bruderschaft) (\(stufe))" }
            return bruderschaft
        }
    }

    /// Lädt `result[0]` aus get_user.php (~1 s). Enthält Profilfelder und die
    /// parallelen Arrays der Fahrten der aktuellen Stufe.
    private func fetchUserResult(aspirantID: String) async throws -> [String: Any]? {
        guard let url = URL(
            string: "https://\(Self.host)/wp-content/themes/lotsen-pwa/get_user.php?id=\(aspirantID)"
        ) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await perform(request)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [[String: Any]] else {
            return nil
        }
        return result.first
    }

    /// Wertet die kompakten Nutzerdaten aus (Name, Bruderschaft, Stufe, Fahrtenzahl).
    private func fetchUserData(aspirantID: String) async throws -> UserData? {
        guard let first = try await fetchUserResult(aspirantID: aspirantID) else { return nil }
        return UserData(
            displayName: (first["display_name"] as? String)?.trimmedNonEmpty,
            bruderschaft: (first["bruderschaft"] as? String)?.trimmedNonEmpty,
            stufe: (first["stufe"] as? String)?.trimmedNonEmpty,
            fahrtenAnzahl: Self.intValue(first["total_number_of_drives"])
                ?? (first["drives_unique_ids"] as? [Any])?.count
        )
    }

    /// Liest einen Int aus einem Wert, der als Zahl oder als String vorliegen kann.
    private static func intValue(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    // MARK: - Fahrten-Download

    /// Lädt die aktuelle Fahrtenliste (für die aktuelle Stufe) über get_user.php.
    func loadDrives() async throws -> [Drive] {
        guard let aspirantID else { throw LogbuchError.unexpected }
        guard let result = try await fetchUserResult(aspirantID: aspirantID) else {
            throw LogbuchError.unexpected
        }

        let ids = result["drives_unique_ids"] as? [Any] ?? []
        let ships = result["ship_names"] as? [Any] ?? []
        let dates = result["on_board_dates"] as? [Any] ?? []

        var drives: [Drive] = []
        drives.reserveCapacity(ids.count)
        for (index, idValue) in ids.enumerated() {
            guard let uid = Self.stringValue(idValue)?.trimmedNonEmpty else { continue }
            let ship = (index < ships.count ? Self.stringValue(ships[index]) : nil)?
                .trimmedNonEmpty ?? "N-A"
            let date = (index < dates.count ? Self.stringValue(dates[index]) : nil)?
                .trimmedNonEmpty ?? ""
            // Die Seite vergibt driveNumber = 1 + Index.
            drives.append(Drive(uniqueID: uid, driveNumber: index + 1, shipName: ship, onBoardDate: date))
        }
        return drives
    }

    /// Lädt eine URL und prüft den HTTP-Status (2xx). `nonisolated`, damit mehrere
    /// Downloads echt parallel laufen (statt durch die MainActor-Isolation serialisiert).
    nonisolated private func fetchValidatedData(from url: URL) async throws -> Data {
        let (data, response) = try await perform(URLRequest(url: url))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LogbuchError.server(http.statusCode)
        }
        return data
    }

    /// Lädt das PDF einer Fahrt.
    nonisolated func downloadPDF(for drive: Drive) async throws -> Data {
        guard let url = URL(
            string: "https://\(Self.host)/wp-content/themes/lotsen-pwa/printable_drive.php"
                + "?unique_id=\(drive.uniqueID)&driveNumber=\(drive.driveNumber)"
        ) else { throw LogbuchError.unexpected }
        return try await fetchValidatedData(from: url)
    }

    /// Lädt das „Stufe als PDF"-Dokument (Ausbildungsstand) des Nutzers.
    func downloadStufePDF(stufe: String) async throws -> Data {
        guard let aspirantID else { throw LogbuchError.unexpected }
        guard let url = URL(
            string: "https://\(Self.host)/wp-content/themes/lotsen-pwa/print_user.php"
                + "?overrideStufe=\(stufe)&id=\(aspirantID)"
        ) else { throw LogbuchError.unexpected }
        return try await fetchValidatedData(from: url)
    }

    /// Fügt die PDFs aller Fahrten **chronologisch** (älteste zuerst, nach dem
    /// Fahrtdatum) zu einem einzigen Dokument zusammen. Ein optionales `prepend`
    /// (z. B. das Stufen-PDF) wird ganz vorne eingefügt.
    /// `nonisolated`, damit es im Hintergrund laufen kann.
    nonisolated static func mergePDFsChronologically(
        _ items: [(drive: Drive, data: Data)],
        prepend: Data? = nil
    ) -> Data? {
        let ordered = items.sorted { lhs, rhs in
            let a = dateRank(lhs.drive.onBoardDate)
            let b = dateRank(rhs.drive.onBoardDate)
            return a != b ? a < b : lhs.drive.driveNumber < rhs.drive.driveNumber
        }

        let merged = PDFDocument()
        var sources: [PDFDocument] = []  // bis zum Schreiben am Leben halten

        func appendPages(_ data: Data) {
            guard let doc = PDFDocument(data: data) else { return }
            sources.append(doc)
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i) {
                    merged.insert(page, at: merged.pageCount)
                }
            }
        }

        if let prepend { appendPages(prepend) }   // Stufen-PDF ganz vorne
        for item in ordered { appendPages(item.data) }

        guard merged.pageCount > 0 else { return nil }
        let result = merged.dataRepresentation()
        sources.removeAll()  // Quell-Dokumente erst jetzt freigeben
        return result
    }

    /// Wandelt "TT.MM.JJJJ" in eine sortierbare Zahl JJJJMMTT.
    nonisolated static func dateRank(_ date: String) -> Int {
        let p = date.split(separator: ".").compactMap { Int($0) }   // [TT, MM, JJJJ]
        guard p.count == 3 else { return 0 }
        return p[2] * 10000 + p[1] * 100 + p[0]
    }

    /// Bestimmt die Ziel-Dateinamen analog zum Browser-Skript:
    /// `JJJJ.MM.T[ (n)] Schiffsname.pdf` – `(n)` nur bei mehreren Fahrten am selben Tag.
    /// Heruntergeladen wird in absteigender driveNumber-Reihenfolge (neueste zuerst).
    static func prepareDownloads(_ drives: [Drive]) -> [DriveDownload] {
        // Datum je Fahrt einmal zerlegen: Tagesschlüssel + Anzeigedatum.
        let parsed = Dictionary(uniqueKeysWithValues: drives.map {
            ($0.uniqueID, germanDate($0.onBoardDate))
        })

        // Nach Tag gruppieren (Schlüssel JJJJ-MM-TT).
        var byDay: [String: [Drive]] = [:]
        for drive in drives {
            byDay[parsed[drive.uniqueID]?.key ?? drive.onBoardDate, default: []].append(drive)
        }

        var fileNames: [String: String] = [:]  // uniqueID -> Dateiname
        for (_, dayDrives) in byDay {
            let sorted = dayDrives.sorted { $0.driveNumber < $1.driveNumber }
            for (index, drive) in sorted.enumerated() {
                let suffix = sorted.count > 1 ? " (\(index + 1))" : ""
                let dateName = parsed[drive.uniqueID]?.name ?? drive.onBoardDate
                let raw = "\(dateName)\(suffix) \(drive.shipName).pdf"
                fileNames[drive.uniqueID] = sanitizeFileName(raw)
            }
        }

        return drives
            .sorted { $0.driveNumber > $1.driveNumber }
            .map { DriveDownload(drive: $0, fileName: fileNames[$0.uniqueID] ?? "\($0.uniqueID).pdf") }
    }

    /// Zerlegt "TT.MM.JJJJ" in einen sortierbaren Schlüssel ("JJJJ-MM-TT") und
    /// ein Anzeigedatum ("JJJJ.MM.T", Tag ohne führende Null).
    private static func germanDate(_ date: String) -> (key: String, name: String) {
        let parts = date.split(separator: ".")
        guard parts.count == 3 else { return (date, date) }
        let name = Int(parts[0]).map { "\(parts[2]).\(parts[1]).\($0)" } ?? date
        return ("\(parts[2])-\(parts[1])-\(parts[0])", name)
    }

    /// Ersetzt für Dateinamen unzulässige Zeichen durch "_".
    static func sanitizeFileName(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "\\/:*?\"<>|")
        return name.components(separatedBy: illegal).joined(separator: "_")
    }

    // MARK: - Profil-HTML (Fallback)

    /// Liest den Namen aus dem Profil-HTML.
    ///
    /// Die Seite zeigt Vor- und Nachname in zwei Elementor-Überschriften:
    ///   `<div id="user_firstname" …><h2 class="elementor-heading-title …">Max</h2>`
    ///   `<div id="user_lastname"  …><h2 class="elementor-heading-title …">Mustermann</h2>`
    /// Fällt auf `nil` zurück, wenn nichts gefunden wird.
    static func extractDisplayName(from html: String) -> String? {
        let firstName = heading(forElementID: "user_firstname", in: html)
        let lastName = heading(forElementID: "user_lastname", in: html)

        let parts = [firstName, lastName].compactMap { $0 }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
    }

    /// Liest das Revier aus dem Profil-HTML.
    ///
    /// Der lesbare Wert wird per JavaScript gesetzt:
    ///   `jQuery("#logged-user-brotherhood").html("Beispiel-Revier (LA1)");`
    /// (Das statische Element enthält nur einen Slug wie "nordostseekanaleins".)
    /// Fällt auf `nil` zurück, wenn nichts gefunden wird.
    static func extractRevier(from html: String) -> String? {
        let pattern = #"#logged-user-brotherhood"\)\.html\("([^"]*)"\)"#
        guard let raw = firstCaptureGroup(of: pattern, in: html) else { return nil }
        let revier = decodeHTML(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return revier.isEmpty ? nil : revier
    }

    /// Leitet die Stufe (z. B. "LA1") aus dem Revier ab – sie steht dort in Klammern,
    /// z. B. "Beispiel-Revier (LA1)".
    static func extractStufe(from revier: String) -> String? {
        guard let raw = firstCaptureGroup(of: #"\(\s*([A-Za-z]+\s*\d+)\s*\)"#, in: revier) else {
            return nil
        }
        let stufe = raw.replacingOccurrences(of: " ", with: "")
        return stufe.isEmpty ? nil : stufe
    }

    /// Liest die Aspirant-ID aus dem CSV-Download-Link der Profilseite, z. B.
    /// `csv_data_structure.php?id='+12345`.
    static func extractAspirantID(from html: String) -> String? {
        let pattern = #"csv_data_structure\.php\?id=['+\s]*(\d+)"#
        return firstCaptureGroup(of: pattern, in: html)
    }

    /// Sucht den Text der ersten `<h2 class="elementor-heading-title …">`-Überschrift,
    /// die nach dem Element mit der angegebenen `id` folgt.
    private static func heading(forElementID id: String, in html: String) -> String? {
        let pattern = "id=\"\(NSRegularExpression.escapedPattern(for: id))\".*?"
            + "<h2[^>]*elementor-heading-title[^>]*>(.*?)</h2>"
        guard let raw = firstCaptureGroup(of: pattern, in: html) else { return nil }
        return decodeHTML(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstCaptureGroup(of pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }

    private static let htmlEntities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                                       "&#039;": "'", "&#39;": "'", "&apos;": "'", "&nbsp;": " "]

    /// Entschlüsselt die gängigsten HTML-Entities, die in Namen vorkommen können.
    private static func decodeHTML(_ string: String) -> String {
        var result = string
        for (entity, char) in htmlEntities {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        return result
    }

    // MARK: - Cookies

    private func setTestCookie() {
        guard let storage = session.configuration.httpCookieStorage else { return }
        if let cookie = HTTPCookie(properties: [
            .domain: ".\(Self.host)",
            .path: "/",
            .name: "wordpress_test_cookie",
            .value: "WP Cookie check",
        ]) {
            storage.setCookie(cookie)
        }
    }

    /// Liefert den Benutzernamen aus dem `wordpress_logged_in_*`-Cookie,
    /// sofern eine gültige Session besteht.
    private func loggedInUsername() -> String? {
        guard let cookies = session.configuration.httpCookieStorage?.cookies else { return nil }
        guard let cookie = cookies.first(where: { $0.name.hasPrefix("wordpress_logged_in_") }),
              !cookie.value.isEmpty else {
            return nil
        }
        // Cookie-Wert: "username|expiry|token|hmac" (URL-codiert).
        let decoded = cookie.value.removingPercentEncoding ?? cookie.value
        let username = decoded.split(separator: "|").first.map(String.init) ?? decoded
        return username.isEmpty ? nil : username
    }

    // MARK: - Hilfsfunktionen

    nonisolated private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw LogbuchError.network(error.localizedDescription)
        }
    }

    private func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = fields.map { key, value -> String in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }
        return pairs.joined(separator: "&").data(using: .utf8) ?? Data()
    }
}

private extension String {
    /// Der getrimmte String, oder `nil`, wenn danach leer.
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
