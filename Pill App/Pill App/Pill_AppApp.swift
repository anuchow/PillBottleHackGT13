//
//  Pill_AppApp.swift
//  Pill App
//
//  Created by Prathithi Nellaiappan on 9/26/26.
//

import SwiftUI
import SwiftData

@main
struct PillTrackerApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()          // was LabelScannerView()
        }
        .modelContainer(for: [Prescription.self, DoseLog.self])
    }
}

