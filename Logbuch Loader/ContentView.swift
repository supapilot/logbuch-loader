//
//  ContentView.swift
//  Logbuch Loader
//
//  Created by Supapilot on 16.06.26.
//

import SwiftUI
import Observation
import AppKit
import Combine
import PDFKit
import UniformTypeIdentifiers

/// Sortierbare Spalte der Fahrten-Liste.
enum DriveSortField { case number, id, ship, date }

@Observable
final class LoginViewModel {
    var username = ""
    var password = ""
    var isLoading = false
    var isRestoring = false
    var errorMessage: String?
    var user: LogbuchUser?

    // Download-Status
    var isDownloading = false
    var isMerging = false
    var downloadProgress = 0.0          // 0 … 1
    var downloadDone = 0
    var downloadTotal = 0
    var downloadMessage = ""            // Ergebnis- bzw. Fehlertext
    var downloadFailed = false
    var downloadCancelled = false

    /// Feste Parallelität: bis zu fünf Downloads gleichzeitig.
    private let concurrency = 5
    var targetFolderURL: URL?

    /// Dateien der Composer-Felder (im Model, damit „Logbuch laden" sie direkt
    /// befüllen kann). Reihenfolge wie die Felder: Ausbildungsplan … Zertifikate.
    var composerFiles: [[URL]] = Array(repeating: [], count: 6)

    // Fahrten-Liste (Einzel-Download)
    var drives: [DriveDownload] = []            // vorbereitet, geladen von loadDrivesList
    var isLoadingDrives = false
    var drivesError: String?
    var singleDownloadID: String?               // uniqueID der gerade ladenden Fahrt
    var singleDownloadMessage: String?
    var singleDownloadFailed = false
    var downloadedDriveIDs: Set<String> = []    // erfolgreich geladen (grünes Häkchen)

    // Auswahl + Sortierung + Sammel-Download
    var selectedDriveIDs: Set<String> = []
    var driveSort: DriveSortField = .number
    var driveSortAscending = false              // Nr. absteigend als Standard
    var isDownloadingSelected = false
    var selectedDone = 0
    var selectedTotal = 0

    /// Die Fahrten in der aktuell gewählten Sortierung.
    var sortedDrives: [DriveDownload] {
        let asc = driveSortAscending
        func by<T: Comparable>(_ key: (DriveDownload) -> T) -> [DriveDownload] {
            drives.sorted { asc ? key($0) < key($1) : key($0) > key($1) }
        }
        switch driveSort {
        case .number: return by { $0.drive.driveNumber }
        case .id:     return by { Int($0.drive.uniqueID) ?? 0 }
        case .ship:   return by { $0.drive.shipName.lowercased() }
        case .date:   return by { LogbuchService.dateRank($0.drive.onBoardDate) }
        }
    }

    var allDrivesSelected: Bool { !drives.isEmpty && selectedDriveIDs.count == drives.count }

    func toggleSort(_ field: DriveSortField) {
        if driveSort == field {
            driveSortAscending.toggle()
        } else {
            driveSort = field
            driveSortAscending = true           // neue Spalte zunächst aufsteigend
        }
    }

    func toggleSelection(_ id: String) {
        if selectedDriveIDs.remove(id) == nil { selectedDriveIDs.insert(id) }
    }

    func toggleSelectAll() {
        if allDrivesSelected { selectedDriveIDs.removeAll() }
        else { selectedDriveIDs = Set(drives.map(\.drive.uniqueID)) }
    }

    @ObservationIgnored private let service = LogbuchService()
    @ObservationIgnored private var downloadTask: Task<Void, Never>?

    init() {
        // Beim App-Start keine übrig gebliebenen Import-Dateien aus einer
        // früheren Sitzung (composerFiles ist per Vorgabe bereits leer).
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("ComposerImport", isDirectory: true))
    }

    var downloadHeadline: String {
        if isMerging { return "Füge zusammen …" }
        if isDownloading { return "Lädt Fahrten …" }
        if downloadCancelled { return "Abgebrochen" }
        if downloadFailed { return "Fehler" }
        if !downloadMessage.isEmpty { return "Fertig" }
        return "Bereit"
    }

    var downloadDetail: String {
        if isMerging { return "" }
        if isDownloading { return "\(downloadDone) / \(downloadTotal)" }
        return downloadMessage
    }

    /// Beim App-Start: gespeicherte Anmeldedaten laden und automatisch anmelden.
    func attemptAutoLogin() async {
        guard user == nil, let credentials = KeychainStore.load() else { return }
        username = credentials.username
        password = credentials.password
        isRestoring = true
        defer { isRestoring = false }
        await login()
    }

    func login() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            user = try await service.login(username: username, password: password)
            // Erfolgreiche Anmeldedaten dauerhaft im Schlüsselbund sichern.
            KeychainStore.save(Credentials(
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            ))
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // Bei falschen Zugangsdaten keine veralteten Daten gespeichert lassen.
            if case LogbuchError.invalidCredentials = error {
                KeychainStore.clear()
            }
        }
    }

    func logout() {
        cancelDownload()
        service.reset()
        KeychainStore.clear()
        user = nil
        password = ""
        errorMessage = nil
        resetDownloadState()
        drives = []
        drivesError = nil
        singleDownloadID = nil
        singleDownloadMessage = nil
        singleDownloadFailed = false
        downloadedDriveIDs = []
        selectedDriveIDs = []
        isDownloadingSelected = false
        selectedDone = 0
        selectedTotal = 0
        driveSort = .number
        driveSortAscending = false
    }

    /// Was beim Klick passiert: einzelne Dateien oder eine zusammengeführte PDF.
    enum DownloadMode { case individual, merged }

    private func resetDownloadState() {
        isMerging = false
        downloadProgress = 0
        downloadDone = 0
        downloadTotal = 0
        downloadMessage = ""
        downloadFailed = false
        downloadCancelled = false
    }

    /// Öffnet den Ordnerdialog und merkt sich den Zielordner.
    func chooseTargetFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Auswählen"
        panel.message = "Zielordner für die Fahrten-PDFs wählen"
        if panel.runModal() == .OK {
            targetFolderURL = panel.url
        }
    }

    /// Startet einen Download. Fragt zunächst den Zielordner ab und lädt dann
    /// mit fester Parallelität.
    func startDownload(mode: DownloadMode) {
        guard !isDownloading else { return }
        chooseTargetFolder()
        guard let folder = targetFolderURL else { return }

        let concurrency = self.concurrency
        downloadTask = Task { await self.performDownload(folder: folder, concurrency: concurrency, mode: mode) }
    }

    /// Bricht einen laufenden Download ab.
    func cancelDownload() {
        downloadTask?.cancel()
    }

    /// Lädt einmalig die Fahrtenliste der aktuellen Stufe (für die Einzel-Download-Liste).
    /// Die Reihenfolge (absteigend nach Fahrt-Nr.) und die Dateinamen liefert
    /// `prepareDownloads` – identisch zu „Fahrten laden".
    func loadDrivesList() async {
        guard drives.isEmpty, !isLoadingDrives else { return }
        isLoadingDrives = true
        drivesError = nil
        defer { isLoadingDrives = false }
        do {
            let list = try await service.loadDrives()
            drives = LogbuchService.prepareDownloads(list)
        } catch {
            drivesError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Gleitendes Fenster: lädt `items` mit höchstens `concurrency` parallelen
    /// Downloads und ruft `onResult` in Abschlussreihenfolge auf. Bricht ab,
    /// sobald der umgebende Task abgebrochen wird.
    private func downloadWindow(
        _ items: [DriveDownload],
        concurrency: Int,
        onResult: (DriveDownload, Data?) -> Void
    ) async {
        let service = self.service
        var iterator = items.makeIterator()
        await withTaskGroup(of: (DriveDownload, Data?).self) { group in
            func startNext() -> Bool {
                guard !Task.isCancelled, let item = iterator.next() else { return false }
                group.addTask { (item, try? await service.downloadPDF(for: item.drive)) }
                return true
            }
            var inFlight = 0
            for _ in 0..<max(1, concurrency) where startNext() { inFlight += 1 }
            while inFlight > 0, let (item, data) = await group.next() {
                inFlight -= 1
                onResult(item, data)
                if startNext() { inFlight += 1 }
            }
        }
    }

    /// Lädt eine einzelne Fahrt als PDF in einen frei gewählten Zielordner. Der
    /// Dateiname entspricht dem von „Fahrten laden" (aus `prepareDownloads`).
    func downloadSingle(_ item: DriveDownload) {
        guard singleDownloadID == nil, !isDownloadingSelected, !isDownloading else { return }
        chooseTargetFolder()
        guard let folder = targetFolderURL else { return }

        singleDownloadID = item.drive.uniqueID
        singleDownloadMessage = nil
        singleDownloadFailed = false
        let service = self.service
        Task {
            defer { singleDownloadID = nil }
            do {
                let data = try await service.downloadPDF(for: item.drive)
                let accessing = folder.startAccessingSecurityScopedResource()
                defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
                try data.write(to: folder.appendingPathComponent(item.fileName), options: .atomic)
                downloadedDriveIDs.insert(item.drive.uniqueID)
                singleDownloadFailed = false
                singleDownloadMessage = "\(item.fileName) gespeichert."
            } catch {
                singleDownloadFailed = true
                singleDownloadMessage = "Download fehlgeschlagen: "
                    + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// Lädt alle aktuell ausgewählten Fahrten (mit fester Parallelität) in einen
    /// frei gewählten Zielordner; Dateinamen wie bei „Fahrten laden".
    func downloadSelected() {
        guard !isDownloadingSelected, singleDownloadID == nil, !isDownloading else { return }
        let items = drives.filter { selectedDriveIDs.contains($0.drive.uniqueID) }
        guard !items.isEmpty else { return }
        chooseTargetFolder()
        guard let folder = targetFolderURL else { return }

        isDownloadingSelected = true
        selectedDone = 0
        selectedTotal = items.count
        singleDownloadMessage = nil
        singleDownloadFailed = false
        let concurrency = self.concurrency
        Task {
            defer { isDownloadingSelected = false }
            let accessing = folder.startAccessingSecurityScopedResource()
            defer { if accessing { folder.stopAccessingSecurityScopedResource() } }

            var failures = 0
            await downloadWindow(items, concurrency: concurrency) { item, data in
                if let data {
                    do {
                        try data.write(to: folder.appendingPathComponent(item.fileName), options: .atomic)
                        downloadedDriveIDs.insert(item.drive.uniqueID)
                    } catch { failures += 1 }
                } else {
                    failures += 1
                }
                selectedDone += 1
            }

            singleDownloadFailed = failures > 0
            singleDownloadMessage = failures == 0
                ? "\(items.count) Fahrten gespeichert."
                : "\(items.count - failures)/\(items.count) gespeichert, \(failures) fehlgeschlagen."
            if failures == 0 { selectedDriveIDs.removeAll() }
        }
    }

    private func performDownload(folder: URL, concurrency: Int, mode: DownloadMode) async {
        resetDownloadState()
        isDownloading = true
        defer { isDownloading = false; isMerging = false }

        do {
            let drives = try await service.loadDrives()
            let items = LogbuchService.prepareDownloads(drives)
            downloadTotal = items.count
            guard downloadTotal > 0 else {
                downloadMessage = "Keine Fahrten gefunden."
                downloadFailed = true
                return
            }

            let accessing = folder.startAccessingSecurityScopedResource()
            defer { if accessing { folder.stopAccessingSecurityScopedResource() } }

            var failures = 0
            var collected: [(item: DriveDownload, data: Data)] = []   // für Merge + Composer

            // Gleitendes Fenster: höchstens `concurrency` Downloads gleichzeitig.
            await downloadWindow(items, concurrency: concurrency) { item, data in
                if let data {
                    switch mode {
                    case .individual:
                        do {
                            try data.write(to: folder.appendingPathComponent(item.fileName), options: .atomic)
                        } catch {
                            failures += 1
                        }
                    case .merged:
                        collected.append((item, data))
                    }
                } else {
                    failures += 1
                }
                downloadDone += 1
                downloadProgress = Double(downloadDone) / Double(downloadTotal)
            }

            if Task.isCancelled {
                downloadCancelled = true
                downloadMessage = "Abgebrochen – \(downloadDone - failures) von \(downloadTotal) geladen."
                return
            }

            switch mode {
            case .individual:
                downloadFailed = failures > 0
                downloadMessage = failures == 0
                    ? "\(downloadDone) PDFs gespeichert."
                    : "\(downloadDone - failures)/\(downloadTotal) gespeichert, \(failures) fehlgeschlagen."

            case .merged:
                isMerging = true
                // Stufen-PDF (Ausbildungsstand) laden – zählt nicht in den Status,
                // wird aber ganz vorne in die fertige PDF eingefügt.
                var stufePDF: Data?
                if let stufe = user?.stufe {
                    stufePDF = try? await service.downloadStufePDF(stufe: stufe)
                }

                // Service führt die PDFs chronologisch (älteste zuerst) zusammen.
                let pairs = collected.map { (drive: $0.item.drive, data: $0.data) }
                let prepend = stufePDF
                let mergedData = await Task.detached {
                    LogbuchService.mergePDFsChronologically(pairs, prepend: prepend)
                }.value
                isMerging = false

                // Komponenten direkt in die passenden Composer-Felder legen:
                // Stufen-PDF → „Ausbildungsstand", Fahrten → „Ausbildungsfahrten".
                importIntoComposer(stufePDF: stufePDF, drives: collected)

                guard let mergedData else {
                    downloadFailed = true
                    downloadMessage = "Zusammenführen fehlgeschlagen."
                    return
                }
                do {
                    try mergedData.write(to: folder.appendingPathComponent("Logbuch.pdf"), options: .atomic)
                    downloadFailed = failures > 0
                    downloadMessage = failures == 0
                        ? "Logbuch.pdf gespeichert (\(collected.count) Fahrten)."
                        : "Logbuch.pdf gespeichert (\(collected.count) Fahrten, \(failures) fehlten)."
                } catch {
                    downloadFailed = true
                    downloadMessage = "Logbuch.pdf konnte nicht gespeichert werden."
                }
            }
        } catch {
            downloadFailed = true
            downloadMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Schreibt die Logbuch-Komponenten in ein Import-Verzeichnis und legt sie in
    /// den passenden Composer-Feldern ab: Stufen-PDF → „Ausbildungsstand", die
    /// einzelnen Fahrten (datierte Dateinamen) → „Ausbildungsfahrten". Die
    /// chronologische Reihenfolge ergibt der Composer aus den Dateinamen.
    private func importIntoComposer(stufePDF: Data?, drives: [(item: DriveDownload, data: Data)]) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComposerImport", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if let stufePDF {
            let url = dir.appendingPathComponent("Ausbildungsstand.pdf")
            if (try? stufePDF.write(to: url)) != nil {
                composerFiles[1] = [url]   // „Ausbildungsstand"
            }
        }

        var driveURLs: [URL] = []
        for entry in drives {
            let url = dir.appendingPathComponent(entry.item.fileName)
            if (try? entry.data.write(to: url)) != nil { driveURLs.append(url) }
        }
        if !driveURLs.isEmpty {
            composerFiles[2] = driveURLs   // „Ausbildungsfahrten"
        }
    }
}

struct ContentView: View {
    @State private var model = LoginViewModel()
    @State private var selectedView: AppView = .downloader

    /// Die beiden Hauptansichten, umschaltbar über den Segment-Switcher.
    enum AppView: String, CaseIterable, Identifiable {
        case downloader = "Downloader"
        case composer = "Composer"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 16) {
            AppHeader()

            // Der Ansicht-Switcher erscheint erst nach erfolgreicher Anmeldung.
            if let user = model.user {
                Picker("Ansicht", selection: $selectedView) {
                    ForEach(AppView.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .center)

                switch selectedView {
                case .downloader:
                    ProfileView(model: model, user: user)
                case .composer:
                    ComposerView(model: model, user: user)
                }
            } else if model.isRestoring {
                RestoringView()
            } else {
                LoginView(model: model)
            }

            AppFooter()
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(minWidth: 500)
        .padding()
        .task { await model.attemptAutoLogin() }
        .onChange(of: model.user == nil) { _, loggedOut in
            // Nach dem Abmelden wieder auf die Downloader-Ansicht zurücksetzen.
            if loggedOut { selectedView = .downloader }
        }
    }

}

/// Composer-Ansicht: Profil & Status (sofern angemeldet) plus sechs
/// Drag-&-Drop-Felder in zwei Spalten.
struct ComposerView: View {
    @Bindable var model: LoginViewModel
    let user: LogbuchUser?

    /// Beschriftung der sechs Felder (in Rasterreihenfolge).
    private let titles = [
        "Ausbildungsplan",
        "Ausbildungsstand",
        "Ausbildungsfahrten",
        "Simulatorfahrten",
        "Tagesprotokolle",
        "Zertifikate",
    ]

    /// Kurze Anweisung pro Feld (gleiche Reihenfolge wie `titles`). Einzahl bei
    /// einer erwarteten Datei, „alle …" bei mehreren.
    private let infoTexts = [
        "Füge hier den Ausbildungsplan ein.",
        "Füge hier den Ausbildungsstand ein. Wird automatisch übernommen, wenn du im Downloader „Logbuch laden“ nutzt.",
        "Füge hier alle Ausbildungsfahrten hinzu. Werden automatisch übernommen, wenn du im Downloader „Logbuch laden“ nutzt.",
        "Füge hier alle Simulatorfahrten hinzu.",
        "Füge hier alle Tagesprotokolle hinzu.",
        "Füge hier alle Zertifikate hinzu.",
    ]

    /// Kurze Rückmeldung nach dem Erstellen (Erfolg oder Fehler).
    @State private var resultMessage: String?
    @State private var resultIsError = false

    /// Gewählte Lotsenbrüderschaft (Revier) – bestimmt das Logo im
    /// Ausbildungsbuch. Auswahl wird über App-Neustarts hinweg gemerkt.
    @AppStorage("composerBrotherhoodID") private var brotherhoodID: String = ""
    /// Läuft gerade ein Erstellungsvorgang (inkl. Logo-Download)?
    @State private var isBuilding = false

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
    ]

    /// Ob in irgendeinem Feld mindestens eine Datei liegt.
    private var hasFiles: Bool { !model.composerFiles.allSatisfy(\.isEmpty) }

    var body: some View {
        VStack(spacing: 18) {
            if let user {
                ProfileStatusBox(user: user,
                                 onLogout: { model.logout() },
                                 logoutDisabled: model.isDownloading)
            }

            GroupBox {
                HStack(spacing: 8) {
                    Picker("Lotsenbrüderschaft", selection: $brotherhoodID) {
                        Text("Bitte wählen …").tag("")
                        ForEach(Brotherhood.all) { revier in
                            Text(revier.name).tag(revier.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    InfoButton(text: "Die Logos sind Eigentum der jeweiligen Lotsenbrüderschaften. Mit dem Erstellen des Ausbildungsbuchs wird bestätigt, vorab die Erlaubnis zur Nutzung des Logos eingeholt zu haben.")
                        .font(.body)
                }
            } label: {
                HStack(spacing: 6) {
                    Text("Lotsenbrüderschaft")
                    InfoButton(text: "Optional: Wähle deine Lotsenbrüderschaft, dann erscheint ihr Logo im Ausbildungsbuch. Ohne Auswahl wird es ohne Logo erstellt.")
                        .font(.body)
                }
            }

            GroupBox {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(model.composerFiles.indices, id: \.self) { index in
                        DropField(title: titles[index], info: infoTexts[index], urls: $model.composerFiles[index])
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text("Unterlagen")
                    InfoButton(text: "Lege die jeweiligen Unterlagen in das passende Feld – als PDF einzeln oder gesammelt als ZIP. Verwende die Originaldateien möglichst unbearbeitet und ohne sie umzubenennen, damit sie korrekt einsortiert werden. Sobald alles eingefügt ist, erstellt der Button „Ausbildungsbuch erstellen“ das fertige Ausbildungsbuch automatisch.")
                        .font(.body)
                }
            }

            VStack(spacing: 8) {
                Button {
                    createLogbook()
                } label: {
                    HStack(spacing: 6) {
                        if isBuilding { ProgressView().controlSize(.small) }
                        Label(isBuilding ? "Ausbildungsbuch wird erstellt …" : "Ausbildungsbuch erstellen",
                              systemImage: "book.closed")
                            .font(.body)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!hasFiles || isBuilding)

                if let resultMessage {
                    Text(resultMessage)
                        .font(.subheadline)
                        .foregroundStyle(resultIsError ? .red : .secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)
        }
        .groupBoxStyle(SectionGroupBoxStyle())
        .frame(maxWidth: 500)
        .padding(.top, 4)
    }

    /// Baut das vollständige Ausbildungsbuch (Deckblatt, Inhaltsverzeichnis,
    /// Kapitel-Deckblätter, Inhalte – alles A4) und fragt per Speichern-Dialog
    /// nach dem Zielort (Vorgabe: Ausbildungsbuch.pdf).
    private func createLogbook() {
        guard hasFiles, !isBuilding else { return }
        guard let user else {
            resultIsError = true
            resultMessage = "Nicht angemeldet."
            return
        }
        // Eine Lotsenbrüderschaft ist optional. Ist keine gewählt, wird das
        // Ausbildungsbuch ohne Logo erstellt (ohne Platzhalter).
        let revier = Brotherhood.named(brotherhoodID)

        isBuilding = true
        resultMessage = nil
        Task {
            defer { isBuilding = false }

            // Logo der gewählten Lotsenbrüderschaft von der BLK-Website laden
            // (bewusst nicht in der App gespeichert). Schlägt das Laden fehl,
            // wird das Buch trotzdem – dann eben ohne Logo – erstellt.
            var logo: NSImage?
            var logoNote = ""
            if let revier {
                do {
                    let (data, _) = try await URLSession.shared.data(from: revier.logoURL)
                    guard let image = NSImage(data: data) else { throw URLError(.cannotDecodeContentData) }
                    logo = image
                } catch {
                    logoNote = " (ohne Logo – es konnte nicht geladen werden)"
                }
            }

            guard let data = LogbookComposer.build(fieldFiles: model.composerFiles, user: user, logo: logo) else {
                resultIsError = true
                resultMessage = "Das Ausbildungsbuch konnte nicht erstellt werden."
                return
            }

            let panel = NSSavePanel()
            panel.title = "Ausbildungsbuch speichern"
            panel.nameFieldStringValue = LogbookComposer.suggestedFileName(fieldFiles: model.composerFiles, user: user)
            panel.allowedContentTypes = [.pdf]
            panel.isExtensionHidden = false

            guard panel.runModal() == .OK, let target = panel.url else { return }

            do {
                try data.write(to: target)
                resultIsError = false
                resultMessage = "Ausbildungsbuch gespeichert: \(target.lastPathComponent)\(logoNote)"
            } catch {
                resultIsError = true
                resultMessage = "Speichern fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }
}

/// Ein einzelnes Drag-&-Drop-Feld mit Überschrift. Nimmt PDF-Dateien per
/// Finder-Drop **oder** per Klick (Datei-Dialog) an und zeigt sie als
/// gestapeltes Dokument-Icon mit Anzahl; „X" entfernt alle wieder.
struct DropField: View {
    let title: String
    let info: String
    @Binding var urls: [URL]
    @State private var isTargeted = false
    @State private var isHovering = false

    private var highlight: Bool { isTargeted || isHovering }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                InfoButton(text: info)
                Spacer(minLength: 0)
            }

            dropBox
        }
    }

    private var dropBox: some View {
        content
            .frame(maxWidth: .infinity)
            .frame(height: 100)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        highlight ? Color.accentColor : Color.secondary.opacity(0.4),
                        style: StrokeStyle(lineWidth: highlight ? 2 : 1.5, dash: [6, 4])
                    )
            )
            .overlay(alignment: .topTrailing) {
                if !urls.isEmpty {
                    Button {
                        urls.removeAll()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .help("Alle Dateien entfernen")
                }
            }
            .onHover { isHovering = $0 }
            .onTapGesture { chooseFiles() }
            .help("Klicken zum Auswählen oder PDFs hierher ziehen")
            .dropDestination(for: URL.self) { items, _ in
                let accepted = items.filter { ["pdf", "zip"].contains($0.pathExtension.lowercased()) }
                guard !accepted.isEmpty else { return false }
                urls.append(contentsOf: accepted)
                return true
            } isTargeted: { isTargeted = $0 }
    }

    @ViewBuilder
    private var content: some View {
        if urls.isEmpty {
            Image(systemName: "arrow.down.doc")
                .font(.title)
                .foregroundStyle(highlight ? Color.accentColor : .secondary)
        } else {
            VStack(spacing: 6) {
                Image(systemName: urls.count > 1 ? "doc.on.doc.fill" : "doc.fill")
                    .font(.largeTitle)
                    .foregroundStyle(highlight ? Color.accentColor : .secondary)
                Text(urls.count == 1 ? "1 Datei" : "\(urls.count) Dateien")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Öffnet den Finder-Dialog zur manuellen Auswahl einer oder mehrerer PDFs.
    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "PDF- oder ZIP-Dateien auswählen"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf, .zip]
        if panel.runModal() == .OK {
            urls.append(contentsOf: panel.urls)
        }
    }
}

struct LoginView: View {
    @Bindable var model: LoginViewModel
    @FocusState private var focusedField: Field?

    enum Field { case username, password }

    private var canSubmit: Bool {
        !model.isLoading
            && !model.username.trimmingCharacters(in: .whitespaces).isEmpty
            && !model.password.isEmpty
    }

    var body: some View {
        VStack(spacing: 20) {
            GroupBox {
                VStack(spacing: 12) {
                    FieldRow(systemImage: "person.fill") {
                        TextField("Benutzername", text: $model.username)
                            .textContentType(.username)
                            .focused($focusedField, equals: .username)
                            .onSubmit { focusedField = .password }
                    }

                    FieldRow(systemImage: "lock.fill") {
                        SecureField("Passwort", text: $model.password)
                            .textContentType(.password)
                            .focused($focusedField, equals: .password)
                            .onSubmit { submit() }
                    }

                    Button(action: submit) {
                        HStack {
                            if model.isLoading {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(model.isLoading ? "Anmelden …" : "Anmelden")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
                    .padding(.top, 2)

                    if let error = model.errorMessage {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .textFieldStyle(.plain)
                .disabled(model.isLoading)
            } label: {
                Text("Anmeldung")
            }
        }
        .groupBoxStyle(SectionGroupBoxStyle())
        .frame(maxWidth: 380)
        .onAppear { focusedField = .username }
    }

    private func submit() {
        guard canSubmit else { return }
        focusedField = nil
        Task { await model.login() }
    }
}

/// Einheitlicher Stil für die „Boxen": etwas größere Überschrift und mehr
/// Abstand zwischen Überschrift und Inhalt.
struct SectionGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            configuration.label
                .font(.title3.weight(.semibold))
            configuration.content
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.2))
                )
        }
    }
}

/// Zwei gleich breite Spalten mit mittigem Trennstrich.
struct SplitRow<Left: View, Right: View>: View {
    @ViewBuilder var left: Left
    @ViewBuilder var right: Right

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            left
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 16)
            Divider()
            right
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 16)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Logo und Titel der App. Zeigt die Icon-Grafik direkt aus dem Asset-Katalog –
/// nicht `applicationIconImage`, das die Grafik auf die graue System-Kachel legt.
struct AppHeader: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSImage(named: "AppIcon") ?? NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 72, height: 72)
                // Gerundete Ecken wie ein macOS-App-Icon (Squircle, ~22,37 %).
                .clipShape(RoundedRectangle(cornerRadius: 72 * 0.2237, style: .continuous))
            Text("Logbuch Loader")
                .font(.title2.bold())
        }
    }
}

/// Dezente Fußzeile: Version, Open-Source-Lizenz, Entwickler und Link zum
/// Quellcode.
struct AppFooter: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 2) {
            Divider()
                .padding(.bottom, 4)
            HStack(spacing: 5) {
                Text("Logbuch Loader \(version)")
                Text("·")
                Link("Open Source", destination: URL(string: "https://github.com/supapilot/logbuch-loader")!)
                Text("·")
                Text("© 2026 Supapilot")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }
}

/// Übergangsbildschirm, während die gespeicherte Anmeldung wiederhergestellt wird.
struct RestoringView: View {
    var body: some View {
        VStack(spacing: 20) {
            ProgressView("Anmeldung wird wiederhergestellt …")
                .controlSize(.large)
        }
    }
}

extension View {
    /// Hintergrund und Rahmen eines eingebetteten Eingabefelds (abgerundet).
    func roundedFieldBackground() -> some View {
        background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.3))
        )
    }
}

/// Ein eingebettetes Eingabefeld mit einem SF-Symbol am Anfang.
struct FieldRow<Content: View>: View {
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            content
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .roundedFieldBackground()
    }
}

/// Box „Profil & Status": Initialen + Name/Revier links, Fahrtenzahl rechts.
/// Wiederverwendbar in der Downloader- und Composer-Ansicht.
struct ProfileStatusBox: View {
    let user: LogbuchUser
    let onLogout: () -> Void
    let logoutDisabled: Bool

    /// Höhe des Name+Revier-Blocks – der Initialen-Kreis übernimmt sie (bündig).
    @State private var nameBlockHeight: CGFloat = 44

    /// Initialen aus den ersten beiden Namensteilen, z. B. "Max Mustermann" → "MM".
    private var initials: String {
        let letters = user.name
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
        return letters.joined().uppercased()
    }

    var body: some View {
        GroupBox {
            SplitRow {
                HStack(spacing: 12) {
                    InitialsBadge(initials: initials, diameter: nameBlockHeight)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(user.name)
                            .font(.title3.bold())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)

                        if let revier = user.revier {
                            Text(revier)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { nameBlockHeight = $0 }
                }
            } right: {
                StatusView(onLogout: onLogout, logoutDisabled: logoutDisabled)
            }
        } label: {
            Text("Profil & Status")
        }
    }
}

struct ProfileView: View {
    @Bindable var model: LoginViewModel
    let user: LogbuchUser

    var body: some View {
        VStack(spacing: 18) {
            ProfileStatusBox(user: user,
                             onLogout: { model.logout() },
                             logoutDisabled: model.isDownloading)

            GroupBox {
                SplitRow {
                    VStack(spacing: 10) {
                        HStack(spacing: 8) {
                            ActionButton(title: "Fahrten laden", systemImage: "arrow.down.circle",
                                         disabled: model.isDownloading) {
                                model.startDownload(mode: .individual)
                            }
                            InfoButton(text: "Lädt jede Fahrt als eigene PDF-Datei in den Zielordner.")
                        }

                        HStack(spacing: 8) {
                            ActionButton(title: "Logbuch laden", systemImage: "book.closed",
                                         disabled: model.isDownloading) {
                                model.startDownload(mode: .merged)
                            }
                            InfoButton(text: "Lädt alle Fahrten und fügt sie chronologisch zu einer Datei zusammen.")
                        }
                    }
                } right: {
                    DownloadStatusView(model: model, foundCount: user.fahrtenAnzahl)
                }
            } label: {
                Text("Aktionen")
            }

            DrivesBox(model: model)
        }
        .groupBoxStyle(SectionGroupBoxStyle())
        .frame(maxWidth: 500)
        .padding(.top, 4)
        .task { await model.loadDrivesList() }
    }
}

/// Gemeinsame Spaltenmaße für Kopf- und Datenzeilen der Fahrten-Liste.
private enum DriveCol {
    static let spacing: CGFloat = 12
    static let hPadding: CGFloat = 8
    static let select: CGFloat = 18
    static let nr: CGFloat = 34
    static let id: CGFloat = 56
    static let date: CGFloat = 82
    static let action: CGFloat = 22
}

/// Box „Fahrten": scrollbare Liste aller Fahrten der aktuellen Stufe mit
/// Einzel-Download je Zeile sowie Mehrfachauswahl für einen Sammel-Download.
struct DrivesBox: View {
    @Bindable var model: LoginViewModel

    private var anyBusy: Bool { model.singleDownloadID != nil || model.isDownloadingSelected }

    var body: some View {
        GroupBox {
            VStack(spacing: 0) {
                header

                if model.isLoadingDrives {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                } else if let error = model.drivesError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                } else if model.drives.isEmpty {
                    Text("Keine Fahrten gefunden.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.sortedDrives.enumerated()), id: \.element.drive.uniqueID) { index, item in
                                DriveRow(
                                    item: item,
                                    striped: !index.isMultiple(of: 2),
                                    isSelected: model.selectedDriveIDs.contains(item.drive.uniqueID),
                                    isDownloading: model.singleDownloadID == item.drive.uniqueID,
                                    isDownloaded: model.downloadedDriveIDs.contains(item.drive.uniqueID),
                                    anyDownloading: anyBusy,
                                    toggleSelect: { model.toggleSelection(item.drive.uniqueID) },
                                    download: { model.downloadSingle(item) }
                                )
                            }
                        }
                    }
                    .frame(height: 260)
                    // Schwebt zentral unten über der Liste, ohne die Fensterhöhe zu ändern.
                    .overlay(alignment: .bottom) {
                        if !model.selectedDriveIDs.isEmpty {
                            selectionFooter
                                .padding(.bottom, 12)
                        }
                    }
                }

                if let message = model.singleDownloadMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(model.singleDownloadFailed ? .red : .secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text("Fahrten")
                InfoButton(text: "Einzelne Fahrt über das Download-Symbol laden. Für mehrere die Kästchen ankreuzen und den Sammel-Button nutzen.")
                    .font(.body)
            }
        }
    }

    /// Sortierbare, bündige Kopfzeile (gleiche Spaltenmaße wie die Zeilen).
    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: DriveCol.spacing) {
                Toggle("", isOn: Binding(get: { model.allDrivesSelected },
                                         set: { _ in model.toggleSelectAll() }))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .frame(width: DriveCol.select, alignment: .leading)
                    .help("Alle aus-/abwählen")
                    .disabled(model.drives.isEmpty)

                sortHeader("Nr.", .number, width: DriveCol.nr)
                sortHeader("Fahrt-ID", .id, width: DriveCol.id)
                sortHeader("Schiffsname", .ship, width: nil)
                sortHeader("Datum", .date, width: DriveCol.date)
                Spacer().frame(width: DriveCol.action)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, DriveCol.hPadding)
            .padding(.bottom, 6)
            Divider()
        }
    }

    /// Ein klickbarer Spaltenkopf; zeigt bei aktiver Spalte die Sortierrichtung.
    @ViewBuilder
    private func sortHeader(_ title: String, _ field: DriveSortField, width: CGFloat?) -> some View {
        Button { model.toggleSort(field) } label: {
            HStack(spacing: 2) {
                Text(title)
                Image(systemName: model.driveSortAscending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(model.driveSort == field ? 1 : 0)
            }
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Schwebender Sammel-Download-Button (Design wie „Fahrten laden") bzw.
    /// während des Ladens ein kompakter Fortschritt – beide mit Schatten.
    private var selectionFooter: some View {
        Group {
            if model.isDownloadingSelected {
                HStack(spacing: 10) {
                    ProgressView(value: Double(model.selectedDone),
                                 total: Double(max(1, model.selectedTotal)))
                        .frame(width: 160)
                    Text("\(model.selectedDone) / \(model.selectedTotal)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
            } else {
                Button {
                    model.downloadSelected()
                } label: {
                    Label("Ausgewählte Fahrten laden (\(model.selectedDriveIDs.count))",
                          systemImage: "arrow.down.circle")
                        .font(.body)
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.singleDownloadID != nil)
            }
        }
        .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
    }
}

/// Eine Zeile der Fahrten-Liste. Feste Spaltenmaße für bündige Ausrichtung;
/// der Schiffsname füllt den verbleibenden (bewusst größten) Platz.
struct DriveRow: View {
    let item: DriveDownload
    let striped: Bool
    let isSelected: Bool
    let isDownloading: Bool
    let isDownloaded: Bool
    let anyDownloading: Bool
    let toggleSelect: () -> Void
    let download: () -> Void

    var body: some View {
        HStack(spacing: DriveCol.spacing) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in toggleSelect() }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(width: DriveCol.select, alignment: .leading)

            Text("\(item.drive.driveNumber)")
                .frame(width: DriveCol.nr, alignment: .leading)
                .monospacedDigit()
            Text(item.drive.uniqueID)
                .frame(width: DriveCol.id, alignment: .leading)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(item.drive.shipName)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(item.drive.onBoardDate)
                .frame(width: DriveCol.date, alignment: .leading)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Group {
                if isDownloading {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action: download) {
                        Image(systemName: isDownloaded ? "checkmark.circle" : "arrow.down.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isDownloaded ? Color.green : Color.accentColor)
                    .disabled(anyDownloading)
                    .help(isDownloaded ? "Bereits geladen – erneut herunterladen" : "Diese Fahrt herunterladen")
                }
            }
            .frame(width: DriveCol.action, alignment: .leading)
        }
        .font(.callout)
        .padding(.horizontal, DriveCol.hPadding)
        .padding(.vertical, 5)
        .background(striped ? Color.primary.opacity(0.045) : Color.clear)
    }
}

/// Einheitlicher Download-Button – garantiert gleiche Schrift, Höhe und Breite.
struct ActionButton: View {
    let title: String
    let systemImage: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.body)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(disabled)
    }
}

/// Graues Info-Symbol mit Kurzerklärung – Popover nur beim Überfahren,
/// nach 0,3 Sekunden Verzögerung.
struct InfoButton: View {
    let text: String
    @State private var show = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: "info.circle")
            .foregroundStyle(.secondary)
            .onHover { hovering in
                hoverTask?.cancel()
                if hovering {
                    hoverTask = Task {
                        try? await Task.sleep(for: .seconds(0.3))
                        if !Task.isCancelled { show = true }
                    }
                } else {
                    show = false
                }
            }
            .popover(isPresented: $show, arrowEdge: .bottom) {
                Text(text)
                    .font(.callout)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 230)
                    .padding(12)
            }
    }
}

/// Status des Fahrten-Downloads. Vor dem Start nur „Bereit", während des Ladens
/// der Fortschrittsbalken mit Abbrechen, danach das Ergebnis.
struct DownloadStatusView: View {
    @Bindable var model: LoginViewModel
    /// Anzahl der gefundenen Fahrten (aus dem Profil), unter der Überschrift gezeigt.
    var foundCount: Int? = nil

    /// Drehwinkel für die Sanduhr im „Bereit"-Zustand. Springt pro Takt um 180°
    /// im Uhrzeigersinn weiter; die Pause entsteht durch das Timer-Intervall.
    @State private var hourglassAngle: Double = 0

    /// Taktgeber für die Sanduhr: alle 2,4 s ein 180°-Kippen (0,6 s Animation,
    /// danach 1,8 s Pause bis zum nächsten Kippen).
    private let flipTimer = Timer.publish(every: 2.4, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: statusIcon)
                    .rotationEffect(.degrees(isReady ? hourglassAngle : 0))
                Text(model.downloadHeadline)
            }
            .font(.title3.weight(.semibold))
            .foregroundStyle(model.downloadFailed ? .red : .primary)
            .onReceive(flipTimer) { _ in
                guard isReady else { return }
                withAnimation(.easeInOut(duration: 0.6)) {
                    hourglassAngle += 180
                }
            }

            if let foundCount {
                Text("Gefundene Fahrten: \(foundCount)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }

            if model.isDownloading {
                HStack(spacing: 8) {
                    ProgressView(value: model.downloadProgress)

                    if !model.isMerging {
                        Button {
                            model.cancelDownload()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Download abbrechen")
                    }
                }
            }

            if !model.downloadDetail.isEmpty {
                Text(model.downloadDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusIcon: String {
        if model.isMerging { return "doc.on.doc" }
        if model.isDownloading { return "arrow.down.circle" }
        if model.downloadCancelled { return "xmark.circle" }
        if model.downloadFailed { return "exclamationmark.triangle" }
        if !model.downloadMessage.isEmpty { return "checkmark.circle" }
        return "hourglass"
    }

    /// Nur im „Bereit"-Zustand (Sanduhr) wird die Rotation angewendet.
    private var isReady: Bool { statusIcon == "hourglass" }
}

/// Runder, blauer Avatar mit den Initialen des Nutzers. Passt sich Hell/Dunkel an.
struct InitialsBadge: View {
    let initials: String
    var diameter: CGFloat = 52

    private let background = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.16, green: 0.28, blue: 0.46, alpha: 1)   // dunkel: tiefes Blau
            : NSColor(red: 0.78, green: 0.89, blue: 0.99, alpha: 1)   // hell: helles Blau
    })

    private let foreground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.72, green: 0.86, blue: 1.0, alpha: 1)    // dunkel: helles Blau
            : NSColor(red: 0.11, green: 0.27, blue: 0.55, alpha: 1)   // hell: dunkles Blau
    })

    var body: some View {
        Text(initials)
            .font(.system(size: diameter * 0.42, weight: .bold))
            .minimumScaleFactor(0.5)
            .foregroundStyle(foreground)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(background))
    }
}

/// Status-Anzeige: grüner Haken neben „Angemeldet", darunter ein kompakter
/// „Abmelden"-Button (schmaler als Haken + „Angemeldet").
struct StatusView: View {
    let onLogout: () -> Void
    let logoutDisabled: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 6) {
                Text("Angemeldet")
                    .fontWeight(.semibold)

                Button("Abmelden", role: .cancel, action: onLogout)
                    .controlSize(.small)
                    .disabled(logoutDisabled)
            }
        }
        .fixedSize()
    }
}

#Preview("Login") {
    ContentView()
}

#Preview("Profil") {
    let model = LoginViewModel()
    let user = LogbuchUser(
        name: "Max Mustermann",
        username: "MustermannMax",
        revier: "Beispiel-Revier (LA1)",
        stufe: "LA1",
        fahrtenAnzahl: 42
    )
    model.user = user
    return ProfileView(model: model, user: user)
        .padding()
        .frame(width: 520, height: 480)
}
