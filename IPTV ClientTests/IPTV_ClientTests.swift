//
//  IPTV_ClientTests.swift
//  IPTV ClientTests
//
//  Created by Albert Monreal on 2/8/26.
//

import CoreData
import Foundation
import Testing
@testable import IPTV_Client

struct IPTV_ClientTests {

    @MainActor
    @Test func restoresMissingProfileWithoutDuplicatingIt() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let original = ProfileEntity(context: context)
        original.id = UUID()
        original.name = "Living Room"
        original.providerType = ProfileProviderType.xtream.rawValue
        original.server = "https://example.com"
        original.username = "viewer"
        original.password = "secret"
        original.createdAt = Date()
        try context.save()

        let snapshot = ProfileSnapshot(profile: original)
        context.delete(original)
        try context.save()

        let firstRestoreCount = try IPTVDataStore.restoreMissingProfiles(from: [snapshot], in: context)
        let secondRestoreCount = try IPTVDataStore.restoreMissingProfiles(from: [snapshot], in: context)
        let restoredProfiles = try context.fetch(ProfileEntity.fetchRequest())

        #expect(firstRestoreCount == 1)
        #expect(secondRestoreCount == 0)
        #expect(restoredProfiles.count == 1)
        #expect(restoredProfiles.first?.id == snapshot.id)
        #expect(restoredProfiles.first?.name == "Living Room")
        #expect(restoredProfiles.first?.password == "secret")
    }

}
