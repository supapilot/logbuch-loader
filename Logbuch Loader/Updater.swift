//
//  Updater.swift
//  Logbuch Loader
//
//  Automatische Update-Prüfung via Sparkle (Stufe B: Hintergrund-Prüfung +
//  Benachrichtigung; der Nutzer entscheidet über Installieren/Später/Überspringen –
//  kein stilles Auto-Install). Beim ersten Start fragt Sparkle einmalig um
//  Erlaubnis für automatische Prüfungen.
//

import SwiftUI
import Sparkle

/// Hält den Sparkle-Updater über die App-Laufzeit am Leben und spiegelt, ob
/// gerade nach Updates gesucht werden darf (steuert den Menüpunkt-Zustand).
@Observable
final class UpdaterViewModel {
    private let controller: SPUStandardUpdaterController
    var canCheckForUpdates = false
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        // startingUpdater: true startet die geplanten Hintergrund-Prüfungen
        // (respektiert die einmalige Nutzer-Zustimmung beim ersten Start).
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil)

        // Sparkle ändert `canCheckForUpdates` auf dem Main-Thread; von dort
        // aktualisieren wir den beobachtbaren Zustand.
        observation = controller.updater.observe(
            \.canCheckForUpdates, options: [.initial, .new]
        ) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            MainActor.assumeIsolated { self?.canCheckForUpdates = value }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// Menüpunkt „Nach Updates suchen…" für das App-Menü. Deaktiviert, solange
/// gerade eine Prüfung läuft.
struct CheckForUpdatesView: View {
    var updater: UpdaterViewModel

    var body: some View {
        Button("Nach Updates suchen…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
    }
}
