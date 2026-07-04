//
//  IPTVService.swift
//  IPTV Client
//
//  Created by Codex on 2/7/26.
//

import Foundation

enum IPTVServiceError: LocalizedError {
    case invalidServerURL
    case invalidResponse
    case httpError(Int)
    case malformedURL(String)
    case hostResolutionFailed(String)
    case invalidProvider(String)
    case noChannelsReturned
    case unsupportedProviderForContent(ProfileProviderType, IPTVContentType)
    case unsupportedOperation(ProfileProviderType)
    case missingPlaylistURL
    case missingStalkerMAC
    case missingEPGSource

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "The server URL is invalid."
        case .invalidResponse:
            return "The server returned an invalid response."
        case let .httpError(statusCode):
            return "Request failed with status code \(statusCode)."
        case let .malformedURL(rawValue):
            return "The URL is malformed: \(rawValue)"
        case let .hostResolutionFailed(details):
            return "Could not resolve the provider host. \(details)"
        case let .invalidProvider(rawValue):
            return "Unknown profile provider: \(rawValue)"
        case .noChannelsReturned:
            return "No channels were returned for this profile."
        case let .unsupportedProviderForContent(provider, contentType):
            return "\(provider.displayName) does not support \(contentType.displayName) in this build."
        case let .unsupportedOperation(provider):
            return "This operation is not supported for \(provider.displayName)."
        case .missingPlaylistURL:
            return "Playlist URL is required for M3U import."
        case .missingStalkerMAC:
            return "MAC address is required for Stalker portal."
        case .missingEPGSource:
            return "No EPG source is available. Add a custom EPG URL or provide one via your playlist/provider."
        }
    }
}

struct IPTVService {
    func fetchChannels(for profile: ProfileEntity, contentType: IPTVContentType) async throws -> [ChannelPayload] {
        let provider = try providerType(from: profile)

        let channels: [ChannelPayload]
        switch provider {
        case .xtream:
            channels = try await fetchXtreamChannels(for: profile, contentType: contentType)
        case .m3u:
            channels = try await fetchM3UChannels(for: profile, contentType: contentType)
        case .stalker:
            guard contentType == .live else {
                throw IPTVServiceError.unsupportedProviderForContent(provider, contentType)
            }
            channels = try await fetchStalkerChannels(for: profile)
        }

        guard !channels.isEmpty else {
            throw IPTVServiceError.noChannelsReturned
        }

        return channels
    }

    func fetchSeriesEpisodes(for profile: ProfileEntity, seriesID: String) async throws -> [ChannelPayload] {
        let provider = try providerType(from: profile)
        guard provider == .xtream else {
            throw IPTVServiceError.unsupportedOperation(provider)
        }

        let urls = try makePlayerAPIURLCandidates(
            server: profile.server,
            username: profile.username,
            password: profile.password,
            action: "get_series_info",
            extraQueryItems: [URLQueryItem(name: "series_id", value: seriesID)]
        )

        let data = try await fetchData(from: urls)
        let parsedEpisodes = parseXtreamSeriesEpisodes(from: data)
        var episodes: [ChannelPayload] = []
        for episode in parsedEpisodes {
            let streamID = Int64(episode.id)
            let ext = normalizedExtension(episode.containerExtension)

            guard let streamURL = try? makeSeriesEpisodeURL(
                server: profile.server,
                username: profile.username,
                password: profile.password,
                streamID: streamID,
                containerExtension: ext
            ) else {
                continue
            }

            let episodeLabel: String
            if let number = episode.episodeNum {
                episodeLabel = "S\(episode.season)E\(number)"
            } else {
                episodeLabel = "Season \(episode.season)"
            }

            let cleanTitle = episode.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Episode \(episode.id)"
            let title = "\(episodeLabel) \(cleanTitle)"

            episodes.append(
                ChannelPayload(
                    streamID: streamID,
                    externalID: "\(episode.id)",
                    epgChannelID: nil,
                    name: title,
                    streamURL: streamURL.absoluteString,
                    logoURL: nil,
                    categoryName: "Season \(episode.season)",
                    contentType: .series,
                    language: nil
                )
            )
        }

        return episodes.sorted { left, right in
            left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
    }

    func downloadEPG(for profile: ProfileEntity, customURL: String?) async throws -> Data {
        let trimmedCustomURL = customURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedCustomURL.isEmpty {
            let customCandidates = normalizedInputURLCandidates(from: trimmedCustomURL)
            guard !customCandidates.isEmpty else {
                throw IPTVServiceError.malformedURL(trimmedCustomURL)
            }
            return try await fetchData(from: customCandidates)
        }

        let provider = try providerType(from: profile)
        switch provider {
        case .xtream:
            let targetURLs = try makeEPGURLCandidates(
                server: profile.server,
                username: profile.username,
                password: profile.password
            )
            return try await fetchData(from: targetURLs)

        case .m3u:
            let playlistURLs = resolvedPlaylistURLCandidates(from: profile)
            guard !playlistURLs.isEmpty else {
                throw IPTVServiceError.missingPlaylistURL
            }
            let playlistData = try await fetchData(from: playlistURLs)
            guard let epgURL = parseM3UEPGURL(from: playlistData) else {
                throw IPTVServiceError.missingEPGSource
            }
            return try await fetchData(from: epgURL)

        case .stalker:
            throw IPTVServiceError.missingEPGSource
        }
    }

    private func providerType(from profile: ProfileEntity) throws -> ProfileProviderType {
        guard let provider = ProfileProviderType(rawValue: profile.providerType) else {
            throw IPTVServiceError.invalidProvider(profile.providerType)
        }
        return provider
    }

    private func fetchXtreamChannels(
        for profile: ProfileEntity,
        contentType: IPTVContentType
    ) async throws -> [ChannelPayload] {
        switch contentType {
        case .live:
            return try await fetchXtreamStreams(
                for: profile,
                contentType: .live,
                action: "get_live_streams"
            )
        case .movies:
            return try await fetchXtreamStreams(
                for: profile,
                contentType: .movies,
                action: "get_vod_streams"
            )
        case .series:
            return try await fetchXtreamSeries(for: profile)
        }
    }

    private func fetchXtreamStreams(
        for profile: ProfileEntity,
        contentType: IPTVContentType,
        action: String
    ) async throws -> [ChannelPayload] {
        async let categoryLookupTask = fetchXtreamCategoryLookup(for: profile, contentType: contentType)
        let urls = try makePlayerAPIURLCandidates(
            server: profile.server,
            username: profile.username,
            password: profile.password,
            action: action
        )

        let data = try await fetchData(from: urls)
        let streams = parseXtreamStreams(from: data)
        let categoryLookup = await categoryLookupTask

        return streams.compactMap { stream in
            guard stream.streamID > 0 else { return nil }
            let streamName = stream.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (streamName?.isEmpty == false) ? streamName! : "Stream \(stream.streamID)"

            do {
                let streamURL: URL
                switch contentType {
                case .live:
                    streamURL = try makeLiveStreamURL(
                        server: profile.server,
                        username: profile.username,
                        password: profile.password,
                        streamID: stream.streamID,
                        containerExtension: normalizedExtension(stream.containerExtension)
                    )
                case .movies:
                    streamURL = try makeMovieStreamURL(
                        server: profile.server,
                        username: profile.username,
                        password: profile.password,
                        streamID: stream.streamID,
                        containerExtension: normalizedExtension(stream.containerExtension)
                    )
                case .series:
                    return nil
                }

                return ChannelPayload(
                    streamID: stream.streamID,
                    externalID: nil,
                    epgChannelID: stream.epgChannelID,
                    name: name,
                    streamURL: streamURL.absoluteString,
                    logoURL: stream.streamIcon,
                    categoryName: resolvedCategoryName(
                        directName: stream.categoryName,
                        categoryID: stream.categoryID,
                        lookup: categoryLookup
                    ),
                    contentType: contentType,
                    language: stream.language
                )
            } catch {
                return nil
            }
        }
    }

    private func fetchXtreamSeries(for profile: ProfileEntity) async throws -> [ChannelPayload] {
        async let categoryLookupTask = fetchXtreamCategoryLookup(for: profile, contentType: .series)
        let urls = try makePlayerAPIURLCandidates(
            server: profile.server,
            username: profile.username,
            password: profile.password,
            action: "get_series"
        )

        let data = try await fetchData(from: urls)
        let series = parseXtreamSeriesList(from: data)
        let categoryLookup = await categoryLookupTask

        return series.compactMap { item in
            guard let seriesID = item.seriesID else { return nil }
            let title = item.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (title?.isEmpty == false) ? title! : "Series \(seriesID)"

            return ChannelPayload(
                streamID: Int64(seriesID),
                externalID: "\(seriesID)",
                epgChannelID: nil,
                name: name,
                streamURL: "series://\(seriesID)",
                logoURL: item.cover,
                categoryName: resolvedCategoryName(
                    directName: item.categoryName,
                    categoryID: item.categoryID,
                    lookup: categoryLookup
                ),
                contentType: .series,
                language: nil
            )
        }
    }

    private func fetchXtreamCategoryLookup(
        for profile: ProfileEntity,
        contentType: IPTVContentType
    ) async -> [String: String] {
        guard let action = xtreamCategoryAction(for: contentType) else {
            return [:]
        }

        do {
            let urls = try makePlayerAPIURLCandidates(
                server: profile.server,
                username: profile.username,
                password: profile.password,
                action: action
            )
            let data = try await fetchData(from: urls)
            return parseXtreamCategories(from: data)
        } catch {
            return [:]
        }
    }

    private func xtreamCategoryAction(for contentType: IPTVContentType) -> String? {
        switch contentType {
        case .live:
            return "get_live_categories"
        case .movies:
            return "get_vod_categories"
        case .series:
            return "get_series_categories"
        }
    }

    private func fetchM3UChannels(
        for profile: ProfileEntity,
        contentType: IPTVContentType
    ) async throws -> [ChannelPayload] {
        let playlistURLs = resolvedPlaylistURLCandidates(from: profile)
        guard !playlistURLs.isEmpty else {
            throw IPTVServiceError.missingPlaylistURL
        }

        let data = try await fetchData(from: playlistURLs)
        let parsed = try M3UParser.parse(data: data)

        return parsed.filter { $0.contentType == contentType }
    }

    private func fetchStalkerChannels(for profile: ProfileEntity) async throws -> [ChannelPayload] {
        let mac = profile.stalkerMAC?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !mac.isEmpty else {
            throw IPTVServiceError.missingStalkerMAC
        }

        let token = try await stalkerToken(server: profile.server, mac: mac)
        let channels = try await stalkerChannels(server: profile.server, mac: mac, token: token)

        return channels.compactMap { channel in
            let name = channel.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            guard let cmd = channel.cmd, let stream = extractStalkerStreamURL(from: cmd) else { return nil }

            let streamID: Int64
            if let idValue = Int64(channel.id ?? "") {
                streamID = idValue
            } else {
                streamID = stableHashAsInt64(stream)
            }

            return ChannelPayload(
                streamID: streamID,
                externalID: channel.id,
                epgChannelID: nil,
                name: name,
                streamURL: stream,
                logoURL: channel.logo,
                categoryName: nil,
                contentType: .live,
                language: nil
            )
        }
    }

    private func stalkerToken(server: String, mac: String) async throws -> String {
        let url = try makeStalkerPortalURL(server: server, queryItems: [
            URLQueryItem(name: "type", value: "stb"),
            URLQueryItem(name: "action", value: "handshake"),
            URLQueryItem(name: "token", value: ""),
            URLQueryItem(name: "JsHttpRequest", value: "1-xml")
        ])

        var request = URLRequest(url: url)
        request.addValue(stalkerCookie(mac: mac), forHTTPHeaderField: "Cookie")

        let data = try await fetchData(for: request)
        let response = try JSONDecoder().decode(StalkerHandshakeEnvelope.self, from: data)
        guard let token = response.js.token, !token.isEmpty else {
            throw IPTVServiceError.invalidResponse
        }
        return token
    }

    private func stalkerChannels(server: String, mac: String, token: String) async throws -> [StalkerChannelDTO] {
        let url = try makeStalkerPortalURL(server: server, queryItems: [
            URLQueryItem(name: "type", value: "itv"),
            URLQueryItem(name: "action", value: "get_all_channels"),
            URLQueryItem(name: "JsHttpRequest", value: "1-xml")
        ])

        var request = URLRequest(url: url)
        request.addValue(stalkerCookie(mac: mac), forHTTPHeaderField: "Cookie")
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data = try await fetchData(for: request)
        let response = try JSONDecoder().decode(StalkerChannelsEnvelope.self, from: data)
        return response.js.data ?? []
    }

    private func fetchData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw IPTVServiceError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw IPTVServiceError.httpError(httpResponse.statusCode)
        }
        return data
    }

    private func fetchData(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw IPTVServiceError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw IPTVServiceError.httpError(httpResponse.statusCode)
        }
        return data
    }

    private func fetchData(from urls: [URL]) async throws -> Data {
        guard !urls.isEmpty else {
            throw IPTVServiceError.invalidServerURL
        }

        var lastError: Error = IPTVServiceError.invalidServerURL
        var allCannotFindHost = true
        for url in urls {
            do {
                return try await fetchData(from: url)
            } catch {
                lastError = error
                if let urlError = error as? URLError, urlError.code == .cannotFindHost {
                    continue
                }
                allCannotFindHost = false
            }
        }

        if allCannotFindHost {
            let attemptedHosts = Array(Set(urls.compactMap(\.host))).sorted().joined(separator: ", ")
            let attemptedURLs = urls.map(\.absoluteString).joined(separator: " | ")
            throw IPTVServiceError.hostResolutionFailed(
                "Hosts: \(attemptedHosts). Attempted URLs: \(attemptedURLs)"
            )
        }

        throw lastError
    }

    private func makePlayerAPIURLCandidates(
        server: String,
        username: String,
        password: String,
        action: String,
        extraQueryItems: [URLQueryItem] = []
    ) throws -> [URL] {
        let queryItems = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password),
            URLQueryItem(name: "action", value: action)
        ] + extraQueryItems
        return try makeXtreamEndpointURLCandidates(server: server, endpoint: "player_api.php", queryItems: queryItems)
    }

    private func makeEPGURLCandidates(server: String, username: String, password: String) throws -> [URL] {
        let queryItems = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password)
        ]
        return try makeXtreamEndpointURLCandidates(server: server, endpoint: "xmltv.php", queryItems: queryItems)
    }

    private func makeLiveStreamURL(
        server: String,
        username: String,
        password: String,
        streamID: Int64,
        containerExtension: String
    ) throws -> URL {
        guard let baseURL = normalizeServerURL(server) else {
            throw IPTVServiceError.invalidServerURL
        }

        return baseURL
            .appendingPathComponent("live")
            .appendingPathComponent(username)
            .appendingPathComponent(password)
            .appendingPathComponent("\(streamID).\(containerExtension)")
    }

    private func makeMovieStreamURL(
        server: String,
        username: String,
        password: String,
        streamID: Int64,
        containerExtension: String
    ) throws -> URL {
        guard let baseURL = normalizeServerURL(server) else {
            throw IPTVServiceError.invalidServerURL
        }

        return baseURL
            .appendingPathComponent("movie")
            .appendingPathComponent(username)
            .appendingPathComponent(password)
            .appendingPathComponent("\(streamID).\(containerExtension)")
    }

    private func makeSeriesEpisodeURL(
        server: String,
        username: String,
        password: String,
        streamID: Int64,
        containerExtension: String
    ) throws -> URL {
        guard let baseURL = normalizeServerURL(server) else {
            throw IPTVServiceError.invalidServerURL
        }

        return baseURL
            .appendingPathComponent("series")
            .appendingPathComponent(username)
            .appendingPathComponent(password)
            .appendingPathComponent("\(streamID).\(containerExtension)")
    }

    private func makeStalkerPortalURL(server: String, queryItems: [URLQueryItem]) throws -> URL {
        guard let baseURL = normalizeServerURL(server) else {
            throw IPTVServiceError.invalidServerURL
        }

        var components = URLComponents(url: baseURL.appendingPathComponent("portal.php"), resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems
        guard let finalURL = components?.url else {
            throw IPTVServiceError.invalidServerURL
        }
        return finalURL
    }

    private func makeXtreamEndpointURLCandidates(
        server: String,
        endpoint: String,
        queryItems: [URLQueryItem]
    ) throws -> [URL] {
        let baseCandidates = normalizeServerURLCandidates(server)
        guard !baseCandidates.isEmpty else {
            throw IPTVServiceError.invalidServerURL
        }

        var urls: [URL] = []
        for baseCandidate in baseCandidates {
            let strippedBase = stripKnownXtreamEndpoint(from: baseCandidate)
            var components = URLComponents(
                url: strippedBase.appendingPathComponent(endpoint),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = queryItems
            if let url = components?.url {
                urls.append(url)
            }
        }

        let unique = deduplicatedURLs(urls)
        guard !unique.isEmpty else {
            throw IPTVServiceError.invalidServerURL
        }

        return unique
    }

    private func normalizeServerURL(_ rawValue: String) -> URL? {
        let candidates = normalizeServerURLCandidates(rawValue)
        return candidates.first.map { stripKnownXtreamEndpoint(from: $0) }
    }

    private func normalizeServerURLCandidates(_ rawValue: String) -> [URL] {
        let inputCandidates = normalizedInputURLCandidates(from: rawValue)
        return deduplicatedURLs(inputCandidates)
    }

    private func normalizedInputURLCandidates(from rawValue: String) -> [URL] {
        let trimmed = normalizedServerInput(rawValue)
        guard !trimmed.isEmpty else {
            return []
        }

        let cleaned: String
        if trimmed.lowercased().hasPrefix("http://http://") {
            cleaned = "http://\(trimmed.dropFirst("http://http://".count))"
        } else if trimmed.lowercased().hasPrefix("https://https://") {
            cleaned = "https://\(trimmed.dropFirst("https://https://".count))"
        } else {
            cleaned = trimmed
        }

        var rawCandidates: [String] = []
        if cleaned.contains("://") {
            rawCandidates.append(cleaned)
            if cleaned.lowercased().hasPrefix("http://") {
                rawCandidates.append("https://\(cleaned.dropFirst("http://".count))")
            } else if cleaned.lowercased().hasPrefix("https://") {
                rawCandidates.append("http://\(cleaned.dropFirst("https://".count))")
            }
        } else {
            rawCandidates.append("http://\(cleaned)")
            rawCandidates.append("https://\(cleaned)")
        }

        var urls: [URL] = []
        for rawCandidate in rawCandidates {
            guard let parsed = URL(string: rawCandidate) else {
                continue
            }

            if parsed.path.isEmpty {
                if let withSlash = URL(string: rawCandidate.hasSuffix("/") ? rawCandidate : rawCandidate + "/") {
                    urls.append(withSlash)
                } else {
                    urls.append(parsed)
                }
            } else {
                urls.append(parsed)
            }
        }

        return deduplicatedURLs(urls)
    }

    private func normalizedServerInput(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        let punctuationMap: [Character: Character] = [
            "。": ".",
            "．": ".",
            "｡": ".",
            "‐": "-",
            "‑": "-",
            "‒": "-",
            "–": "-",
            "—": "-",
            "﹘": "-",
            "﹣": "-",
            "－": "-"
        ]

        value = String(value.map { punctuationMap[$0] ?? $0 })

        let zeroWidthScalars = CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{FEFF}\u{2060}")
        let filteredScalars = value.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && !zeroWidthScalars.contains(scalar)
        }
        value = String(String.UnicodeScalarView(filteredScalars))

        value = value.replacingOccurrences(of: " ", with: "")
        return value
    }

    private func deduplicatedURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var unique: [URL] = []
        for url in urls {
            let key = url.absoluteString
            if seen.insert(key).inserted {
                unique.append(url)
            }
        }
        return unique
    }

    private func stripKnownXtreamEndpoint(from url: URL) -> URL {
        let knownEndpoints = Set(["get.php", "player_api.php", "xmltv.php", "portal.php"])
        guard knownEndpoints.contains(url.lastPathComponent.lowercased()) else {
            return url
        }

        var stripped = url
        stripped.deleteLastPathComponent()
        return stripped
    }

    private func normalizedExtension(_ value: String?) -> String {
        let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "m3u8" : raw
    }

    private func parseXtreamStreams(from data: Data) -> [XtreamStreamDTO] {
        if let decoded = try? JSONDecoder().decode([XtreamStreamDTO].self, from: data) {
            return decoded
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }
        guard let extractedArray = extractObjectArray(from: root),
              let normalizedData = try? JSONSerialization.data(withJSONObject: extractedArray),
              let decoded = try? JSONDecoder().decode([XtreamStreamDTO].self, from: normalizedData) else {
            return []
        }
        return decoded
    }

    private func parseXtreamSeriesList(from data: Data) -> [XtreamSeriesDTO] {
        if let decoded = try? JSONDecoder().decode([XtreamSeriesDTO].self, from: data) {
            return decoded
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }
        guard let extractedArray = extractObjectArray(from: root),
              let normalizedData = try? JSONSerialization.data(withJSONObject: extractedArray),
              let decoded = try? JSONDecoder().decode([XtreamSeriesDTO].self, from: normalizedData) else {
            return []
        }
        return decoded
    }

    private func parseXtreamCategories(from data: Data) -> [String: String] {
        let categories: [XtreamCategoryDTO]
        if let decoded = try? JSONDecoder().decode([XtreamCategoryDTO].self, from: data) {
            categories = decoded
        } else if let root = try? JSONSerialization.jsonObject(with: data),
                  let extractedArray = extractObjectArray(from: root),
                  let normalizedData = try? JSONSerialization.data(withJSONObject: extractedArray),
                  let decoded = try? JSONDecoder().decode([XtreamCategoryDTO].self, from: normalizedData) {
            categories = decoded
        } else {
            return [:]
        }

        var lookup: [String: String] = [:]
        for category in categories {
            let categoryID = category.categoryID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let categoryName = category.categoryName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !categoryID.isEmpty, !categoryName.isEmpty else { continue }
            lookup[categoryID] = categoryName
        }
        return lookup
    }

    private func resolvedCategoryName(
        directName: String?,
        categoryID: String?,
        lookup: [String: String]
    ) -> String? {
        if let directName = directName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !directName.isEmpty {
            return directName
        }

        guard let categoryID = categoryID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !categoryID.isEmpty else {
            return nil
        }

        return lookup[categoryID]
    }

    private func extractObjectArray(from value: Any, depth: Int = 2) -> [[String: Any]]? {
        if let dictionaries = value as? [[String: Any]], !dictionaries.isEmpty {
            return dictionaries
        }

        if let array = value as? [Any] {
            let dictionaries = array.compactMap { $0 as? [String: Any] }
            if !dictionaries.isEmpty {
                return dictionaries
            }

            guard depth > 0 else { return nil }
            for nested in array {
                if let extracted = extractObjectArray(from: nested, depth: depth - 1) {
                    return extracted
                }
            }
            return nil
        }

        guard depth > 0, let dictionary = value as? [String: Any] else {
            return nil
        }

        let preferredKeys = [
            "data",
            "result",
            "results",
            "channels",
            "available_channels",
            "series",
            "items"
        ]

        for key in preferredKeys {
            if let nested = dictionary[key],
               let extracted = extractObjectArray(from: nested, depth: depth - 1) {
                return extracted
            }
        }

        for nested in dictionary.values {
            if let extracted = extractObjectArray(from: nested, depth: depth - 1) {
                return extracted
            }
        }
        return nil
    }

    private func parseXtreamSeriesEpisodes(from data: Data) -> [ParsedXtreamEpisode] {
        if let decoded = try? JSONDecoder().decode(XtreamSeriesInfoResponse.self, from: data) {
            var episodes: [ParsedXtreamEpisode] = []
            for (season, seasonEpisodes) in decoded.episodes {
                let seasonLabel = season.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "1" : season
                for episode in seasonEpisodes {
                    guard let id = episode.id else { continue }
                    episodes.append(
                        ParsedXtreamEpisode(
                            season: seasonLabel,
                            id: id,
                            title: episode.title,
                            containerExtension: episode.containerExtension,
                            episodeNum: episode.episodeNum
                        )
                    )
                }
            }
            return episodes
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let episodesValue = root["episodes"] else {
            return []
        }

        var episodes: [ParsedXtreamEpisode] = []

        if let seasonDictionary = episodesValue as? [String: Any] {
            for (season, seasonRawEpisodes) in seasonDictionary {
                episodes.append(contentsOf: extractEpisodes(from: seasonRawEpisodes, season: season))
            }
        } else if let rootEpisodesArray = episodesValue as? [Any] {
            episodes.append(contentsOf: extractEpisodes(from: rootEpisodesArray, season: "1"))
        }

        return episodes
    }

    private func extractEpisodes(from rawValue: Any, season: String) -> [ParsedXtreamEpisode] {
        if let dictionaries = rawValue as? [[String: Any]] {
            return dictionaries.compactMap { parseEpisodeDictionary($0, season: season) }
        }
        if let array = rawValue as? [Any] {
            return array.compactMap { item in
                guard let dictionary = item as? [String: Any] else { return nil }
                return parseEpisodeDictionary(dictionary, season: season)
            }
        }
        if let dictionary = rawValue as? [String: Any] {
            return dictionary.compactMap { _, value in
                guard let episodeDictionary = value as? [String: Any] else { return nil }
                return parseEpisodeDictionary(episodeDictionary, season: season)
            }
        }
        return []
    }

    private func parseEpisodeDictionary(_ dictionary: [String: Any], season: String) -> ParsedXtreamEpisode? {
        let rawID = dictionary["id"] ?? dictionary["episode_id"] ?? dictionary["stream_id"]
        guard let id = parseInt(rawID) else {
            return nil
        }

        let title = parseString(dictionary["title"]) ?? parseString(dictionary["name"])
        let extensionValue = parseString(dictionary["container_extension"])
        let episodeNumber = parseInt(dictionary["episode_num"])
        return ParsedXtreamEpisode(
            season: season,
            id: id,
            title: title,
            containerExtension: extensionValue,
            episodeNum: episodeNumber
        )
    }

    private func parseInt(_ value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let int64Value = value as? Int64 {
            return Int(int64Value)
        }
        if let stringValue = value as? String {
            return Int(stringValue)
        }
        if let numberValue = value as? NSNumber {
            return numberValue.intValue
        }
        return nil
    }

    private func parseString(_ value: Any?) -> String? {
        if let stringValue = value as? String {
            return stringValue
        }
        if let numberValue = value as? NSNumber {
            return numberValue.stringValue
        }
        return nil
    }

    private func resolvedPlaylistURLCandidates(from profile: ProfileEntity) -> [URL] {
        let candidates = [
            profile.playlistURL,
            profile.server
        ]

        var urls: [URL] = []
        for candidate in candidates {
            guard let raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            urls.append(contentsOf: normalizedInputURLCandidates(from: raw))
        }

        return deduplicatedURLs(urls)
    }

    private func parseM3UEPGURL(from data: Data) -> URL? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }

        guard let firstLine = text.split(separator: "\n").first else {
            return nil
        }

        let line = String(firstLine)
        guard line.localizedCaseInsensitiveContains("x-tvg-url") || line.localizedCaseInsensitiveContains("url-tvg") else {
            return nil
        }

        let pattern = #"(?:x-tvg-url|url-tvg)\s*=\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: line) else {
            return nil
        }

        return URL(string: String(line[valueRange]))
    }

    private func stalkerCookie(mac: String) -> String {
        "mac=\(mac); stb_lang=en; timezone=UTC;"
    }

    private func extractStalkerStreamURL(from rawCommand: String) -> String? {
        let trimmed = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let range = trimmed.range(of: "http", options: .caseInsensitive) {
            return String(trimmed[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    private func stableHashAsInt64(_ value: String) -> Int64 {
        let data = value.data(using: .utf8) ?? Data()
        var hash: UInt64 = 1469598103934665603
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return Int64(bitPattern: hash)
    }
}

private enum M3UParser {
    static func parse(data: Data) throws -> [ChannelPayload] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return []
        }

        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        var parsedChannels: [ChannelPayload] = []
        var pendingInfo: (name: String, attributes: [String: String], group: String?)?

        for line in lines where !line.isEmpty {
            if line.hasPrefix("#EXTINF") {
                let attributes = parseAttributes(from: line)
                let name = parseName(from: line)
                pendingInfo = (name: name, attributes: attributes, group: attributes["group-title"])
                continue
            }

            if line.hasPrefix("#") {
                continue
            }

            guard let info = pendingInfo else { continue }
            pendingInfo = nil

            let streamURL = line
            let streamID = stableHashAsInt64(streamURL)
            let group = info.group?.trimmingCharacters(in: .whitespacesAndNewlines)
            let epgID = info.attributes["tvg-id"]
            let logo = info.attributes["tvg-logo"]
            let language = info.attributes["tvg-language"] ?? info.attributes["language"]
            let contentType = inferContentType(group: group, name: info.name)

            parsedChannels.append(
                ChannelPayload(
                    streamID: streamID,
                    externalID: nil,
                    epgChannelID: epgID,
                    name: info.name,
                    streamURL: streamURL,
                    logoURL: logo,
                    categoryName: group,
                    contentType: contentType,
                    language: language
                )
            )
        }

        return parsedChannels
    }

    private static func parseAttributes(from line: String) -> [String: String] {
        var attributes: [String: String] = [:]
        let pattern = #"([A-Za-z0-9\-]+)="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return attributes
        }

        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        for match in regex.matches(in: line, options: [], range: range) {
            guard let keyRange = Range(match.range(at: 1), in: line),
                  let valueRange = Range(match.range(at: 2), in: line) else {
                continue
            }

            let key = String(line[keyRange]).lowercased()
            let value = String(line[valueRange])
            attributes[key] = value
        }

        return attributes
    }

    private static func parseName(from line: String) -> String {
        guard let commaIndex = line.lastIndex(of: ",") else {
            return "Unnamed Channel"
        }

        let suffix = line[line.index(after: commaIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix.isEmpty ? "Unnamed Channel" : suffix
    }

    private static func inferContentType(group: String?, name: String) -> IPTVContentType {
        let combined = "\(group ?? "") \(name)".lowercased()
        if combined.contains("movie") || combined.contains("vod") || combined.contains("film") {
            return .movies
        }
        if combined.contains("series") || combined.contains("season") || combined.contains("episode") {
            return .series
        }
        return .live
    }

    private static func stableHashAsInt64(_ value: String) -> Int64 {
        let data = value.data(using: .utf8) ?? Data()
        var hash: UInt64 = 1469598103934665603
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return Int64(bitPattern: hash)
    }
}

private struct XtreamStreamDTO: Decodable {
    let name: String?
    let streamID: Int64
    let epgChannelID: String?
    let streamIcon: String?
    let categoryName: String?
    let categoryID: String?
    let containerExtension: String?
    let language: String?

    enum CodingKeys: String, CodingKey {
        case name
        case streamID = "stream_id"
        case epgChannelID = "epg_channel_id"
        case tvgID = "tvg_id"
        case streamIcon = "stream_icon"
        case categoryName = "category_name"
        case categoryID = "category_id"
        case containerExtension = "container_extension"
        case language
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try? container.decode(String.self, forKey: .name)
        streamIcon = try? container.decode(String.self, forKey: .streamIcon)
        categoryName = container.decodeLossyStringIfPresent(forKey: .categoryName)
        categoryID = container.decodeLossyStringIfPresent(forKey: .categoryID)
        containerExtension = try? container.decode(String.self, forKey: .containerExtension)
        language = try? container.decode(String.self, forKey: .language)

        if let epgID = try? container.decode(String.self, forKey: .epgChannelID),
           !epgID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            epgChannelID = epgID
        } else if let tvgID = try? container.decode(String.self, forKey: .tvgID),
                  !tvgID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            epgChannelID = tvgID
        } else {
            epgChannelID = nil
        }

        if let intValue = try? container.decode(Int64.self, forKey: .streamID) {
            streamID = intValue
        } else if let stringValue = try? container.decode(String.self, forKey: .streamID),
                  let intValue = Int64(stringValue) {
            streamID = intValue
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .streamID,
                in: container,
                debugDescription: "Missing stream ID."
            )
        }
    }
}

private struct XtreamSeriesDTO: Decodable {
    let name: String?
    let seriesID: Int?
    let cover: String?
    let categoryName: String?
    let categoryID: String?

    enum CodingKeys: String, CodingKey {
        case name
        case seriesID = "series_id"
        case cover
        case categoryName = "category_name"
        case categoryID = "category_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try? container.decode(String.self, forKey: .name)
        cover = try? container.decode(String.self, forKey: .cover)
        categoryName = container.decodeLossyStringIfPresent(forKey: .categoryName)
        categoryID = container.decodeLossyStringIfPresent(forKey: .categoryID)

        if let intValue = try? container.decode(Int.self, forKey: .seriesID) {
            seriesID = intValue
        } else if let stringValue = try? container.decode(String.self, forKey: .seriesID),
                  let intValue = Int(stringValue) {
            seriesID = intValue
        } else {
            seriesID = nil
        }
    }
}

private struct XtreamCategoryDTO: Decodable {
    let categoryID: String?
    let categoryName: String?

    enum CodingKeys: String, CodingKey {
        case categoryID = "category_id"
        case categoryName = "category_name"
        case name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        categoryID = container.decodeLossyStringIfPresent(forKey: .categoryID)
        categoryName = container.decodeLossyStringIfPresent(forKey: .categoryName)
            ?? container.decodeLossyStringIfPresent(forKey: .name)
    }
}

private struct XtreamSeriesInfoResponse: Decodable {
    let episodes: [String: [XtreamEpisodeDTO]]
}

private struct ParsedXtreamEpisode {
    let season: String
    let id: Int
    let title: String?
    let containerExtension: String?
    let episodeNum: Int?
}

private struct XtreamEpisodeDTO: Decodable {
    let id: Int?
    let title: String?
    let containerExtension: String?
    let episodeNum: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case containerExtension = "container_extension"
        case episodeNum = "episode_num"
    }
}

private struct StalkerHandshakeEnvelope: Decodable {
    let js: StalkerHandshakeJS
}

private struct StalkerHandshakeJS: Decodable {
    let token: String?
}

private struct StalkerChannelsEnvelope: Decodable {
    let js: StalkerChannelsJS
}

private struct StalkerChannelsJS: Decodable {
    let data: [StalkerChannelDTO]?
}

private struct StalkerChannelDTO: Decodable {
    let id: String?
    let name: String
    let cmd: String?
    let logo: String?
}

private extension KeyedDecodingContainer {
    func decodeLossyStringIfPresent(forKey key: Key) -> String? {
        if let stringValue = try? decode(String.self, forKey: key) {
            return stringValue
        }
        if let intValue = try? decode(Int.self, forKey: key) {
            return String(intValue)
        }
        if let int64Value = try? decode(Int64.self, forKey: key) {
            return String(int64Value)
        }
        if let doubleValue = try? decode(Double.self, forKey: key) {
            return String(doubleValue)
        }
        return nil
    }
}
