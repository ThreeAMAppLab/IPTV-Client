//
//  CoreDataEntities.swift
//  IPTV Client
//
//  Created by Codex on 2/7/26.
//

import CoreData
import Foundation

@objc(ProfileEntity)
public final class ProfileEntity: NSManagedObject {}

extension ProfileEntity {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<ProfileEntity> {
        NSFetchRequest<ProfileEntity>(entityName: "Profile")
    }

    @NSManaged public var id: UUID
    @NSManaged public var name: String
    @NSManaged public var providerType: String
    @NSManaged public var server: String
    @NSManaged public var username: String
    @NSManaged public var password: String
    @NSManaged public var playlistURL: String?
    @NSManaged public var stalkerMAC: String?
    @NSManaged public var createdAt: Date
}

extension ProfileEntity: Identifiable {}

@objc(EPGConfigEntity)
public final class EPGConfigEntity: NSManagedObject {}

extension EPGConfigEntity {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<EPGConfigEntity> {
        NSFetchRequest<EPGConfigEntity>(entityName: "EPGConfig")
    }

    @NSManaged public var id: UUID
    @NSManaged public var profileID: UUID
    @NSManaged public var isEnabled: Bool
    @NSManaged public var customURL: String?
    @NSManaged public var refreshFrequencyHours: Int16
    @NSManaged public var timeShiftHours: Int16
    @NSManaged public var lastRefreshAt: Date?
    @NSManaged public var lastRefreshStatus: String?
    @NSManaged public var lastXMLData: Data?
}

extension EPGConfigEntity: Identifiable {}

@objc(ChannelEntity)
public final class ChannelEntity: NSManagedObject {}

extension ChannelEntity {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<ChannelEntity> {
        NSFetchRequest<ChannelEntity>(entityName: "Channel")
    }

    @NSManaged public var id: UUID
    @NSManaged public var profileID: UUID
    @NSManaged public var streamID: Int64
    @NSManaged public var externalID: String?
    @NSManaged public var epgChannelID: String?
    @NSManaged public var contentType: String
    @NSManaged public var name: String
    @NSManaged public var streamURL: String
    @NSManaged public var logoURL: String?
    @NSManaged public var categoryName: String?
    @NSManaged public var language: String?
    @NSManaged public var isFavorite: Bool
    @NSManaged public var isDownloaded: Bool
    @NSManaged public var localFilePath: String?
    @NSManaged public var lastUpdatedAt: Date
}

extension ChannelEntity: Identifiable {}
