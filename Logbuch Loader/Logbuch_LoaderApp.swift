//
//  Logbuch_LoaderApp.swift
//  Logbuch Loader
//
//  Created by Supapilot on 16.06.26.
//

import SwiftUI
import AppKit

/// Sorgt dafür, dass die App vollständig beendet wird, sobald das letzte
/// Fenster (über den roten X-Button) geschlossen wird.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct Logbuch_LoaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // Fenster genau auf die Inhaltsgröße legen (kein überflüssiger Rand).
        // Hell/Dunkel folgt automatisch den Systemeinstellungen, da kein
        // colorScheme erzwungen wird.
        .windowResizability(.contentSize)
        // Titelleiste (Titeltext + Trennlinie) ausblenden; Ampel-Buttons bleiben.
        .windowStyle(.hiddenTitleBar)
    }
}
