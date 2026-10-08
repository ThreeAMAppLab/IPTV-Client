//
//  ChannelFiltering.swift
//  IPTV Client
//
//  Off-main-thread channel metadata extraction and filtering.
//
//  Building per-channel filter metadata (country/language/EPG token
//  extraction, which runs several regexes + Unicode normalization per row) and
//  filtering the full channel list were both done synchronously on the main
//  thread on every tab switch and every keystroke. On a large IPTV catalog
//  that stalls the UI for seconds — catastrophic on the Apple TV HD's A8 and
//  the reason focus movement appeared to "hang". Everything here operates on
//  Sendable value snapshots so it can run on a background task, leaving the
//  main thread free.
//

import CoreData
import Foundation

/// A cheap, Sendable snapshot of the fields a channel needs for both filtering
/// and display. Built on the main thread (just primitive property reads), then
/// handed to a background task.
struct ChannelRawInfo: Sendable {
    let name: String
    let streamURL: String
    let localFilePath: String?
    let logoURL: String?
    let categoryName: String?
    let epgChannelID: String?
    let language: String?
    let isFavorite: Bool
    let isDownloaded: Bool
    let contentTypeRaw: String

    init(channel: ChannelEntity) {
        name = channel.name
        streamURL = channel.streamURL
        localFilePath = channel.localFilePath
        logoURL = channel.logoURL
        categoryName = channel.categoryName
        epgChannelID = channel.epgChannelID
        language = channel.language
        isFavorite = channel.isFavorite
        isDownloaded = channel.isDownloaded
        contentTypeRaw = channel.contentType
    }
}

/// Precomputed, reusable per-channel filter metadata (the expensive part).
struct ChannelFilterMetadata: Sendable {
    let searchName: String
    let categoryName: String
    let languageToken: String?
    let countryTokens: Set<String>
    let epgCandidateIDs: Set<String>
}

/// The current filter selection, snapshotted so the background task doesn't
/// touch view state.
struct ChannelFilterCriteria: Sendable {
    let cleanTitle: String
    let normalizedTitle: String
    let cleanEPGKeyword: String
    let favoritesOnly: Bool
    let selectedCategoryName: String
    let allCategoryToken: String
    let selectedLanguageToken: String
    let allLanguageToken: String
    let downloadedOnly: Bool
    let isLive: Bool
    let favoriteCountriesOnly: Bool
    let selectedCountryToken: String
    let allCountriesToken: String
    let favoriteCountryTokens: Set<String>
    let fallbackContentTypeRaw: String
}

/// Result of a background processing pass.
struct ChannelProcessingResult: Sendable {
    let matchIndices: [Int]
    let playables: [PlayableChannel]
    let metadata: [ChannelFilterMetadata]
    /// Present only when metadata was rebuilt (i.e. the channel set changed);
    /// nil on a filter-only pass so the caller keeps the existing option lists.
    let categoryOptions: [String]?
    let languageOptions: [String]?
    let countryOptions: [String]?
}

enum ChannelProcessor {
    /// Builds/reuses metadata, applies the filter, and produces the ordered
    /// player playlist — all off the main thread.
    ///
    /// - Parameter cachedMetadata: pass the previous pass's metadata when only
    ///   the filter (not the channel set) changed, to skip the expensive
    ///   token-extraction rebuild.
    static func process(
        rawInfos: [ChannelRawInfo],
        cachedMetadata: [ChannelFilterMetadata]?,
        criteria: ChannelFilterCriteria,
        epgIndex: EPGIndex?
    ) -> ChannelProcessingResult {
        let rebuiltMetadata: [ChannelFilterMetadata]? = (cachedMetadata?.count == rawInfos.count)
            ? nil
            : rawInfos.map { metadata(for: $0, epgIndex: epgIndex) }
        let resolvedMetadata = rebuiltMetadata ?? cachedMetadata ?? []

        let matchingEPGChannelIDs: Set<String>? =
            (criteria.isLive && !criteria.cleanEPGKeyword.isEmpty)
            ? epgIndex?.matchingChannelIDs(keyword: criteria.cleanEPGKeyword)
            : nil

        var matchIndices: [Int] = []
        var playables: [PlayableChannel] = []
        matchIndices.reserveCapacity(rawInfos.count)
        playables.reserveCapacity(rawInfos.count)

        for index in rawInfos.indices {
            let raw = rawInfos[index]
            let meta = resolvedMetadata[index]
            guard matches(
                raw: raw,
                meta: meta,
                criteria: criteria,
                matchingEPGChannelIDs: matchingEPGChannelIDs
            ) else { continue }

            matchIndices.append(index)
            playables.append(
                PlayableChannel(
                    title: raw.name,
                    streamURL: raw.streamURL,
                    localFilePath: raw.localFilePath,
                    logoURL: raw.logoURL,
                    contentTypeRaw: raw.contentTypeRaw.isEmpty ? criteria.fallbackContentTypeRaw : raw.contentTypeRaw
                )
            )
        }

        // Option lists only change when the underlying channel set changed.
        var categoryOptions: [String]?
        var languageOptions: [String]?
        var countryOptions: [String]?
        if rebuiltMetadata != nil {
            categoryOptions = Array(Set(resolvedMetadata.map(\.categoryName).filter { !$0.isEmpty }))
            languageOptions = Array(Set(resolvedMetadata.compactMap(\.languageToken)))
            if criteria.isLive {
                var countries = Set<String>()
                for meta in resolvedMetadata {
                    countries.formUnion(meta.countryTokens)
                }
                countryOptions = Array(countries)
            } else {
                countryOptions = []
            }
        }

        return ChannelProcessingResult(
            matchIndices: matchIndices,
            playables: playables,
            metadata: resolvedMetadata,
            categoryOptions: categoryOptions,
            languageOptions: languageOptions,
            countryOptions: countryOptions
        )
    }

    /// Builds just the per-channel metadata (the expensive token-extraction
    /// pass), without filtering — used to warm every content type's cache up
    /// front so switching tabs later is instant.
    static func buildMetadata(rawInfos: [ChannelRawInfo], epgIndex: EPGIndex?) -> [ChannelFilterMetadata] {
        rawInfos.map { metadata(for: $0, epgIndex: epgIndex) }
    }

    private static func matches(
        raw: ChannelRawInfo,
        meta: ChannelFilterMetadata,
        criteria: ChannelFilterCriteria,
        matchingEPGChannelIDs: Set<String>?
    ) -> Bool {
        if !criteria.cleanTitle.isEmpty, !meta.searchName.contains(criteria.normalizedTitle) {
            return false
        }

        if criteria.favoritesOnly, !raw.isFavorite {
            return false
        }

        if criteria.selectedCategoryName != criteria.allCategoryToken {
            if meta.categoryName.caseInsensitiveCompare(criteria.selectedCategoryName) != .orderedSame {
                return false
            }
        }

        if !criteria.isLive {
            if criteria.selectedLanguageToken != criteria.allLanguageToken {
                if meta.languageToken != criteria.selectedLanguageToken {
                    return false
                }
            }
            if criteria.downloadedOnly, !raw.isDownloaded {
                return false
            }
        } else {
            if !criteria.favoriteCountriesOnly, criteria.selectedCountryToken != criteria.allCountriesToken {
                if !meta.countryTokens.contains(criteria.selectedCountryToken) {
                    return false
                }
            }

            if criteria.favoriteCountriesOnly {
                if criteria.favoriteCountryTokens.isEmpty
                    || meta.countryTokens.isDisjoint(with: criteria.favoriteCountryTokens) {
                    return false
                }
            }

            if !criteria.cleanEPGKeyword.isEmpty {
                guard let matchingEPGChannelIDs else { return false }
                if meta.epgCandidateIDs.isEmpty || meta.epgCandidateIDs.isDisjoint(with: matchingEPGChannelIDs) {
                    return false
                }
            }
        }

        return true
    }

    private static func metadata(for raw: ChannelRawInfo, epgIndex: EPGIndex?) -> ChannelFilterMetadata {
        ChannelFilterMetadata(
            searchName: raw.name.localizedLowercase,
            categoryName: raw.categoryName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            languageToken: languageToken(name: raw.name, language: raw.language),
            countryTokens: countryTokens(
                name: raw.name,
                categoryName: raw.categoryName,
                epgChannelID: raw.epgChannelID,
                epgIndex: epgIndex
            ),
            epgCandidateIDs: epgCandidateIDs(
                name: raw.name,
                epgChannelID: raw.epgChannelID,
                epgIndex: epgIndex
            )
        )
    }

    private static func countryTokens(
        name: String,
        categoryName: String?,
        epgChannelID: String?,
        epgIndex: EPGIndex?
    ) -> Set<String> {
        var tokens = CountryExtractor.extractTokens(from: name)
        if let categoryName {
            tokens.formUnion(CountryExtractor.extractTokens(from: categoryName))
        }
        if !tokens.isEmpty {
            return tokens
        }

        guard let epgIndex,
              let explicitID = epgChannelID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !explicitID.isEmpty else {
            return []
        }
        return epgIndex.countries(forChannelID: explicitID)
    }

    private static func epgCandidateIDs(
        name: String,
        epgChannelID: String?,
        epgIndex: EPGIndex?
    ) -> Set<String> {
        guard let epgIndex else { return [] }

        var candidateIDs = Set<String>()
        if let explicitID = epgChannelID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicitID.isEmpty {
            candidateIDs.insert(explicitID)
        }
        candidateIDs.formUnion(epgIndex.candidateChannelIDs(forChannelName: name))
        return candidateIDs
    }

    private static func languageToken(name: String, language: String?) -> String? {
        if let rawLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawLanguage.isEmpty {
            let upper = rawLanguage.uppercased()
            if upper.count <= 3, upper.allSatisfy(\.isLetter) {
                return upper
            }

            let normalized = upper.replacingOccurrences(of: "-", with: " ")
            if normalized.contains("EN") || normalized.contains("ENGLISH") { return "EN" }
            if normalized.contains("FR") || normalized.contains("FRENCH") { return "FR" }
            if normalized.contains("ES") || normalized.contains("SPANISH") { return "ES" }
            if normalized.contains("PT") || normalized.contains("PORTUGUESE") { return "PT" }
            if normalized.contains("AR") || normalized.contains("ARABIC") { return "AR" }
        }

        let namePrefix = name.split(separator: "|", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let upperPrefix = namePrefix.uppercased()
        if (2...3).contains(upperPrefix.count), upperPrefix.allSatisfy(\.isLetter) {
            return upperPrefix
        }

        return nil
    }
}
