//
//  ProfileCloudBackup.swift
//  IPTV Client
//
//  Keeps the small, irreplaceable profile list in the user's private iCloud
//  database. Channel and EPG rows deliberately remain local/rebuildable.
//

import CloudKit
import CoreData
import Foundation

struct ProfileSnapshot: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var providerType: String
    var server: String
    var username: String
    var password: String
    var playlistURL: String?
    var stalkerMAC: String?
    var createdAt: Date

    @MainActor
    init(profile: ProfileEntity) {
        id = profile.id
        name = profile.name
        providerType = profile.providerType
        server = profile.server
        username = profile.username
        password = profile.password
        playlistURL = profile.playlistURL
        stalkerMAC = profile.stalkerMAC
        createdAt = profile.createdAt
    }
}

actor ProfileCloudBackup {
    static let shared = ProfileCloudBackup()

    private static let recordType = "IPTVProfileBackup"
    private static let recordName = "profiles-v1"
    private static let payloadKey = "payload"

    private let database: CKDatabase
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(container: CKContainer = .default()) {
        database = container.privateCloudDatabase
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    /// Merges local profiles into the cloud copy. Local values win for matching
    /// identifiers, while cloud-only values are returned for local restoration.
    func synchronize(localProfiles: [ProfileSnapshot]) async throws -> [ProfileSnapshot] {
        let (record, cloudProfiles) = try await fetchBackup()
        var mergedByID = Dictionary(uniqueKeysWithValues: cloudProfiles.map { ($0.id, $0) })
        for profile in localProfiles {
            mergedByID[profile.id] = profile
        }

        let merged = Self.sorted(Array(mergedByID.values))
        if merged != Self.sorted(cloudProfiles) {
            try await save(merged, using: record)
        }
        return merged
    }

    func upsert(_ profile: ProfileSnapshot) async throws {
        let (record, profiles) = try await fetchBackup()
        var profilesByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        profilesByID[profile.id] = profile
        try await save(Self.sorted(Array(profilesByID.values)), using: record)
    }

    func remove(profileID: UUID) async throws {
        let (record, profiles) = try await fetchBackup()
        let updated = profiles.filter { $0.id != profileID }
        guard updated.count != profiles.count else { return }
        try await save(Self.sorted(updated), using: record)
    }

    private func fetchBackup() async throws -> (CKRecord?, [ProfileSnapshot]) {
        let recordID = CKRecord.ID(recordName: Self.recordName)
        let results = try await database.records(for: [recordID], desiredKeys: [Self.payloadKey])

        guard let result = results[recordID] else {
            return (nil, [])
        }

        switch result {
        case .success(let record):
            guard let data = record[Self.payloadKey] as? Data else {
                return (record, [])
            }
            return (record, try decoder.decode([ProfileSnapshot].self, from: data))

        case .failure(let error):
            if let cloudError = error as? CKError, cloudError.code == .unknownItem {
                return (nil, [])
            }
            throw error
        }
    }

    private func save(_ profiles: [ProfileSnapshot], using existingRecord: CKRecord?) async throws {
        let record = existingRecord ?? CKRecord(
            recordType: Self.recordType,
            recordID: CKRecord.ID(recordName: Self.recordName)
        )
        record[Self.payloadKey] = try encoder.encode(profiles) as CKRecordValue

        let result = try await database.modifyRecords(
            saving: [record],
            deleting: [],
            savePolicy: .changedKeys,
            atomically: true
        )

        if let saveResult = result.saveResults[record.recordID] {
            _ = try saveResult.get()
        }
    }

    private static func sorted(_ profiles: [ProfileSnapshot]) -> [ProfileSnapshot] {
        profiles.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt < $1.createdAt
        }
    }
}

extension IPTVDataStore {
    @MainActor
    static func profileSnapshots(in context: NSManagedObjectContext) throws -> [ProfileSnapshot] {
        let request = ProfileEntity.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \ProfileEntity.createdAt, ascending: true)]
        return try context.fetch(request).map(ProfileSnapshot.init(profile:))
    }

    /// Restores only missing profiles so an older cloud copy never overwrites a
    /// newer local edit. Returns the number of profiles restored.
    @MainActor
    @discardableResult
    static func restoreMissingProfiles(
        from snapshots: [ProfileSnapshot],
        in context: NSManagedObjectContext
    ) throws -> Int {
        let request = ProfileEntity.fetchRequest()
        let existingIDs = Set(try context.fetch(request).map(\.id))
        var restoredCount = 0

        for snapshot in snapshots where !existingIDs.contains(snapshot.id) {
            let profile = ProfileEntity(context: context)
            profile.id = snapshot.id
            profile.name = snapshot.name
            profile.providerType = snapshot.providerType
            profile.server = snapshot.server
            profile.username = snapshot.username
            profile.password = snapshot.password
            profile.playlistURL = snapshot.playlistURL
            profile.stalkerMAC = snapshot.stalkerMAC
            profile.createdAt = snapshot.createdAt
            restoredCount += 1
        }

        if context.hasChanges {
            try context.save()
        }
        return restoredCount
    }
}
