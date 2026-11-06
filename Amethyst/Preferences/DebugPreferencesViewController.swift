//
//  DebugPreferencesViewController.swift
//  Amethyst
//
//  Created by Ian Ynda-Hummel on 3/9/19.
//  Copyright © 2019 Ian Ynda-Hummel. All rights reserved.
//

import AppKit
import Foundation

class DebugPreferencesViewController: NSViewController {
    @IBOutlet weak var revealWindowTitlesButton: NSButton?

    /// The preferences the pane reads; the app's shared ones unless a test supplies its own.
    var configuration = UserConfiguration.shared

    private var preferencesObserver: NSObjectProtocol?

    override func viewDidLoad() {
        super.viewDidLoad()

        preferencesObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateRevealWindowTitlesButton()
        }
        updateRevealWindowTitlesButton()
    }

    deinit {
        if let preferencesObserver = preferencesObserver {
            NotificationCenter.default.removeObserver(preferencesObserver)
        }
    }

    /// The profile only matters while something is written to the system log, so the button follows the two logging
    /// checkboxes.
    func updateRevealWindowTitlesButton() {
        revealWindowTitlesButton?.isEnabled = configuration.logsDiagnosticDetails() || configuration.logsWarningsAndErrors()
    }

    /// Hands the bundled logging profile to macOS, which offers to install it in System Settings. Once installed, the
    /// system log on this Mac shows the window titles that are otherwise stored as private data.
    @IBAction func revealWindowTitles(_ sender: AnyObject) {
        guard let profile = Bundle.main.url(forResource: "RevealWindowTitles", withExtension: "mobileconfig") else {
            log.error("The profile that reveals window titles is missing from the app bundle")
            return
        }

        NSWorkspace.shared.open(profile)
    }
}
