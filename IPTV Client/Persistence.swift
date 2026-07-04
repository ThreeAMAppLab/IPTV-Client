//
//  Persistence.swift
//  IPTV Client
//
//  Created by Albert Monreal on 2/8/26.
//

import CoreData

struct PersistenceController {
    static let shared = PersistenceController()

    @MainActor
    static let preview: PersistenceController = {
        let result = PersistenceController(inMemory: true)
        let viewContext = result.container.viewContext
        let demoProfile = ProfileEntity(context: viewContext)
        demoProfile.id = UUID()
        demoProfile.name = "Demo Profile"
        demoProfile.providerType = "xtream"
        demoProfile.server = "https://example.com"
        demoProfile.username = "demo"
        demoProfile.password = "password"
        demoProfile.playlistURL = nil
        demoProfile.stalkerMAC = nil
        demoProfile.createdAt = Date()

        let demoConfig = EPGConfigEntity(context: viewContext)
        demoConfig.id = UUID()
        demoConfig.profileID = demoProfile.id
        demoConfig.isEnabled = true
        demoConfig.customURL = nil
        demoConfig.refreshFrequencyHours = 1
        demoConfig.timeShiftHours = 0
        demoConfig.lastRefreshAt = nil
        demoConfig.lastRefreshStatus = "Not downloaded yet"
        demoConfig.lastXMLData = nil

        do {
            try viewContext.save()
        } catch {
            // Replace this implementation with code to handle the error appropriately.
            // fatalError() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development.
            let nsError = error as NSError
            fatalError("Unresolved error \(nsError), \(nsError.userInfo)")
        }
        return result
    }()

    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "IPTV_Client")
        if inMemory {
            container.persistentStoreDescriptions.first!.url = URL(fileURLWithPath: "/dev/null")
        }
        container.loadPersistentStores(completionHandler: { (storeDescription, error) in
            if let error = error as NSError? {
                // Replace this implementation with code to handle the error appropriately.
                // fatalError() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development.

                /*
                 Typical reasons for an error here include:
                 * The parent directory does not exist, cannot be created, or disallows writing.
                 * The persistent store is not accessible, due to permissions or data protection when the device is locked.
                 * The device is out of space.
                 * The store could not be migrated to the current model version.
                 Check the error message to determine what the actual problem was.
                 */
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }
        })
        container.viewContext.automaticallyMergesChangesFromParent = true
    }
}
