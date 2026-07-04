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
        .commands {
            // „Über Logbuch Loader" mit Open-Source-Hinweis, Entwickler und
            // klickbarem Link zum Quellcode.
            CommandGroup(replacing: .appInfo) {
                Button("Über Logbuch Loader") { showAboutPanel() }
            }
        }
    }

    /// Zeigt das Standard-„Über"-Fenster mit ergänzten Credits (Lizenz,
    /// Entwickler, Quellcode-Link). App-Name, Version und Copyright füllt macOS
    /// automatisch aus der Info.plist.
    private func showAboutPanel() {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: center,
        ]
        func link(_ text: String, _ url: String) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .paragraphStyle: center,
                .link: URL(string: url)!,
            ])
        }
        let newline = NSAttributedString(string: "\n", attributes: base)

        let credits = NSMutableAttributedString(
            string: "Open Source unter der Apache-Lizenz 2.0.\nEntwickelt von Supapilot.\n\n",
            attributes: base)
        credits.append(link("Quellcode auf GitHub", "https://github.com/supapilot/logbuch-loader"))
        credits.append(newline)
        credits.append(link("www.supapilot.dev", "https://www.supapilot.dev"))
        credits.append(newline)
        credits.append(link("hello@supapilot.dev", "mailto:hello@supapilot.dev"))

        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
