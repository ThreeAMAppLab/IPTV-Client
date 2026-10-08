//
//  IPTVDataStore.swift
//  IPTV Client
//
//  Created by Codex on 2/7/26.
//

import CoreData
import Foundation

enum ProfileProviderType: String, CaseIterable, Identifiable {
    case xtream
    case m3u
    case stalker

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .xtream:
            return "Xtream Codes"
        case .m3u:
            return "M3U/M3U8"
        case .stalker:
            return "Stalker Portal"
        }
    }
}

enum IPTVContentType: String, CaseIterable, Identifiable {
    case live
    case series
    case movies

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .live:
            return "Live TV"
        case .series:
            return "Series"
        case .movies:
            return "Movies"
        }
    }
}

struct ChannelPayload {
    let streamID: Int64
    let externalID: String?
    let epgChannelID: String?
    let name: String
    let streamURL: String
    let logoURL: String?
    let categoryName: String?
    let contentType: IPTVContentType
    let language: String?
}

enum IPTVDataStore {
    static func deleteProfiles(_ profiles: [ProfileEntity], in context: NSManagedObjectContext) throws {
        for profile in profiles {
            try deleteRelatedData(profileID: profile.id, in: context)
            context.delete(profile)
        }
        try context.save()
    }

    static func fetchChannels(
        profileID: UUID,
        contentType: IPTVContentType,
        favoritesOnly: Bool = false,
        in context: NSManagedObjectContext
    ) throws -> [ChannelEntity] {
        let request = ChannelEntity.fetchRequest()
        if favoritesOnly {
            request.predicate = NSPredicate(
                format: "profileID == %@ AND contentType == %@ AND isFavorite == YES",
                profileID as CVarArg,
                contentType.rawValue
            )
        } else {
            request.predicate = NSPredicate(
                format: "profileID == %@ AND contentType == %@",
                profileID as CVarArg,
                contentType.rawValue
            )
        }
        request.sortDescriptors = [NSSortDescriptor(keyPath: \ChannelEntity.name, ascending: true)]
        return try context.fetch(request)
    }

    static func fetchDownloadedChannels(profileID: UUID, in context: NSManagedObjectContext) throws -> [ChannelEntity] {
        let request = ChannelEntity.fetchRequest()
        request.predicate = NSPredicate(
            format: "profileID == %@ AND isDownloaded == YES",
            profileID as CVarArg
        )
        request.sortDescriptors = [NSSortDescriptor(keyPath: \ChannelEntity.name, ascending: true)]
        return try context.fetch(request)
    }

    static func fetchOrCreateEPGConfig(profileID: UUID, in context: NSManagedObjectContext) throws -> EPGConfigEntity {
        let request = EPGConfigEntity.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "profileID == %@", profileID as CVarArg)

        if let config = try context.fetch(request).first {
            return config
        }

        let config = EPGConfigEntity(context: context)
        config.id = UUID()
        config.profileID = profileID
        config.isEnabled = true
        config.customURL = nil
        config.refreshFrequencyHours = 1
        config.timeShiftHours = 0
        config.lastRefreshAt = nil
        config.lastRefreshStatus = nil
        config.lastXMLData = nil
        return config
    }

    static func replaceChannels(
        profileID: UUID,
        contentType: IPTVContentType,
        channels: [ChannelPayload],
        in context: NSManagedObjectContext
    ) throws {
        let existingRequest = ChannelEntity.fetchRequest()
        existingRequest.predicate = NSPredicate(
            format: "profileID == %@ AND contentType == %@",
            profileID as CVarArg,
            contentType.rawValue
        )

        let existing = try context.fetch(existingRequest)
        var stateByStreamID: [Int64: (isFavorite: Bool, isDownloaded: Bool, localFilePath: String?)] = [:]
        for channel in existing {
            stateByStreamID[channel.streamID] = (
                isFavorite: channel.isFavorite,
                isDownloaded: channel.isDownloaded,
                localFilePath: channel.localFilePath
            )
            context.delete(channel)
        }

        for payload in channels {
            let channel = ChannelEntity(context: context)
            channel.id = UUID()
            channel.profileID = profileID
            channel.streamID = payload.streamID
            channel.externalID = payload.externalID
            channel.epgChannelID = payload.epgChannelID
            channel.contentType = payload.contentType.rawValue
            channel.name = payload.name
            channel.streamURL = payload.streamURL
            channel.logoURL = payload.logoURL
            channel.categoryName = payload.categoryName
            channel.language = payload.language
            channel.lastUpdatedAt = Date()

            if let preserved = stateByStreamID[payload.streamID] {
                channel.isFavorite = preserved.isFavorite
                channel.isDownloaded = preserved.isDownloaded
                channel.localFilePath = preserved.localFilePath
            } else {
                channel.isFavorite = false
                channel.isDownloaded = false
                channel.localFilePath = nil
            }
        }

        try context.save()
    }

    static func setFavorite(_ isFavorite: Bool, for channel: ChannelEntity, in context: NSManagedObjectContext) throws {
        channel.isFavorite = isFavorite
        try context.save()
    }

    /// Finds the stored channel for a given stream URL (used to toggle/read the
    /// favorite state of whatever is currently playing).
    static func channel(
        profileID: UUID,
        streamURL: String,
        in context: NSManagedObjectContext
    ) throws -> ChannelEntity? {
        let request = ChannelEntity.fetchRequest()
        request.predicate = NSPredicate(
            format: "profileID == %@ AND streamURL == %@",
            profileID as CVarArg,
            streamURL
        )
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    static func setDownloadedState(
        for channel: ChannelEntity,
        isDownloaded: Bool,
        localFilePath: String?,
        in context: NSManagedObjectContext
    ) throws {
        channel.isDownloaded = isDownloaded
        channel.localFilePath = localFilePath
        try context.save()
    }

    static func upsertDownloadedItem(
        profileID: UUID,
        payload: ChannelPayload,
        localFilePath: String,
        in context: NSManagedObjectContext
    ) throws {
        let request = ChannelEntity.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(
            format: "profileID == %@ AND streamID == %lld AND contentType == %@",
            profileID as CVarArg,
            payload.streamID,
            payload.contentType.rawValue
        )

        let channel: ChannelEntity
        if let existing = try context.fetch(request).first {
            channel = existing
        } else {
            channel = ChannelEntity(context: context)
            channel.id = UUID()
            channel.isFavorite = false
        }

        channel.profileID = profileID
        channel.streamID = payload.streamID
        channel.externalID = payload.externalID
        channel.epgChannelID = payload.epgChannelID
        channel.contentType = payload.contentType.rawValue
        channel.name = payload.name
        channel.streamURL = payload.streamURL
        channel.logoURL = payload.logoURL
        channel.categoryName = payload.categoryName
        channel.language = payload.language
        channel.isDownloaded = true
        channel.localFilePath = localFilePath
        channel.lastUpdatedAt = Date()

        try context.save()
    }

    private static func deleteRelatedData(profileID: UUID, in context: NSManagedObjectContext) throws {
        let epgRequest = EPGConfigEntity.fetchRequest()
        epgRequest.predicate = NSPredicate(format: "profileID == %@", profileID as CVarArg)
        let epgConfigs = try context.fetch(epgRequest)
        for config in epgConfigs {
            context.delete(config)
        }

        let channelRequest = ChannelEntity.fetchRequest()
        channelRequest.predicate = NSPredicate(format: "profileID == %@", profileID as CVarArg)
        let channels = try context.fetch(channelRequest)
        for channel in channels {
            context.delete(channel)
        }
    }
}
