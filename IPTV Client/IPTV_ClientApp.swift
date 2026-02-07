//
//  IPTV_ClientApp.swift
//  IPTV Client
//
//  Created by Albert Monreal on 2/8/26.
//

import SwiftUI
import CoreData

@main
struct IPTV_ClientApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
