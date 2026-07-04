//
//  EPGIndex.swift
//  IPTV Client
//
//  Created by Codex on 2/7/26.
//

import Foundation

struct EPGIndex: Sendable {
    let searchableProgramTextByChannelID: [String: String]
    let channelIDsByNormalizedName: [String: Set<String>]
    let countriesByChannelID: [String: Set<String>]

    static func build(from xmlData: Data) -> EPGIndex? {
        let delegate = XMLTVIndexParserDelegate()
        let parser = XMLParser(data: xmlData)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.makeIndex()
    }

    func matches(keyword: String, channelID: String) -> Bool {
        let normalizedKeyword = TextNormalizer.normalizeForSearch(keyword)
        guard !normalizedKeyword.isEmpty else { return true }
        guard let text = searchableProgramTextByChannelID[channelID] else { return false }
        return text.contains(normalizedKeyword)
    }

    func matchingChannelIDs(keyword: String) -> Set<String> {
        let normalizedKeyword = TextNormalizer.normalizeForSearch(keyword)
        guard !normalizedKeyword.isEmpty else {
            return Set(searchableProgramTextByChannelID.keys)
        }

        var matchingIDs = Set<String>()
        matchingIDs.reserveCapacity(searchableProgramTextByChannelID.count)

        for (channelID, text) in searchableProgramTextByChannelID where text.contains(normalizedKeyword) {
            matchingIDs.insert(channelID)
        }

        return matchingIDs
    }

    func candidateChannelIDs(forChannelName channelName: String) -> Set<String> {
        let key = TextNormalizer.normalizeName(channelName)
        return channelIDsByNormalizedName[key] ?? []
    }

    func countries(forChannelID channelID: String) -> Set<String> {
        countriesByChannelID[channelID] ?? []
    }
}

enum CountryExtractor {
    private static let isoRegionCodes = Set(Locale.Region.isoRegions.map { $0.identifier.uppercased() })
    private static let delimitersRegex = try? NSRegularExpression(pattern: #"[\|\[\(]\s*([A-Za-z]{2,3})\s*[\|\]\)]"#)
    private static let aliasToCanonicalCode: [String: String] = [
        "ALB": "AL",
        "ARE": "AE",
        "ARG": "AR",
        "ARM": "AM",
        "AUS": "AU",
        "AUT": "AT",
        "BEL": "BE",
        "BGR": "BG",
        "BIH": "BA",
        "BRA": "BR",
        "CAN": "CA",
        "CHE": "CH",
        "CHN": "CN",
        "CZE": "CZ",
        "DEU": "DE",
        "DNK": "DK",
        "DZA": "DZ",
        "EGY": "EG",
        "ESP": "ES",
        "FIN": "FI",
        "FRA": "FR",
        "GB": "UK",
        "GBR": "UK",
        "GRC": "GR",
        "HRV": "HR",
        "HUN": "HU",
        "IND": "IN",
        "IRL": "IE",
        "ISR": "IL",
        "ITA": "IT",
        "JOR": "JO",
        "JPN": "JP",
        "KOR": "KR",
        "KWT": "KW",
        "LBN": "LB",
        "MAR": "MA",
        "MDA": "MD",
        "MEX": "MX",
        "MKD": "MK",
        "MNE": "ME",
        "NLD": "NL",
        "NOR": "NO",
        "NZL": "NZ",
        "OMN": "OM",
        "PAK": "PK",
        "POL": "PL",
        "PRT": "PT",
        "QAT": "QA",
        "ROU": "RO",
        "RUS": "RU",
        "SAU": "SA",
        "SRB": "RS",
        "SVK": "SK",
        "SVN": "SI",
        "SWE": "SE",
        "SYR": "SY",
        "TUN": "TN",
        "TUR": "TR",
        "UAE": "AE",
        "UK": "UK",
        "UKR": "UA",
        "USA": "US",
        "YEM": "YE"
    ]

    private static let regionNameToCode: [String: String] = {
        var mapping: [String: String] = [:]

        for locale in [Locale.current, Locale(identifier: "en_US_POSIX")] {
            for region in Locale.Region.isoRegions {
                let code = region.identifier.uppercased()
                guard let displayName = locale.localizedString(forRegionCode: code) else { continue }
                let normalizedName = TextNormalizer.normalizeForSearch(displayName)
                guard !normalizedName.isEmpty else { continue }
                mapping[normalizedName] = canonicalCountryToken(code) ?? code
            }
        }

        mapping["britain"] = "UK"
        mapping["great britain"] = "UK"
        mapping["u s a"] = "US"
        mapping["u k"] = "UK"
        mapping["uae"] = "AE"
        mapping["united states of america"] = "US"
        return mapping
    }()

    private static let normalizedRegionNames = regionNameToCode
        .map { (name: $0.key, code: $0.value) }
        .sorted { $0.name.count > $1.name.count }

    static func extractTokens(from rawValue: String) -> Set<String> {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var tokens: Set<String> = []
        let uppercased = trimmed.uppercased()

        if let regex = delimitersRegex {
            let nsRange = NSRange(uppercased.startIndex..<uppercased.endIndex, in: uppercased)
            for match in regex.matches(in: uppercased, options: [], range: nsRange) {
                guard let range = Range(match.range(at: 1), in: uppercased) else { continue }
                let token = String(uppercased[range])
                if let canonical = canonicalCountryToken(token) {
                    tokens.insert(canonical)
                }
            }
        }

        for token in uppercased.split(whereSeparator: { !$0.isLetter }) {
            let candidate = String(token)
            if let canonical = canonicalCountryToken(candidate) {
                tokens.insert(canonical)
            }
        }

        let normalizedRegionName = TextNormalizer.normalizeForSearch(trimmed)
        if !normalizedRegionName.isEmpty {
            let paddedName = " \(normalizedRegionName) "
            for region in normalizedRegionNames where paddedName.contains(" \(region.name) ") {
                tokens.insert(region.code)
            }
        }

        return tokens
    }

    static func displayLabel(for token: String) -> String {
        let canonicalToken = canonicalCountryToken(token) ?? token.uppercased()
        if canonicalToken == "UK" {
            return "UK - United Kingdom"
        }
        if canonicalToken.count == 2,
           let regionName = Locale.current.localizedString(forRegionCode: canonicalToken) {
            return "\(canonicalToken) - \(regionName)"
        }
        return canonicalToken
    }

    private static func canonicalCountryToken(_ token: String) -> String? {
        let uppercasedToken = token.uppercased()
        if let aliasedToken = aliasToCanonicalCode[uppercasedToken] {
            return aliasedToken
        }
        if uppercasedToken.count == 2, isoRegionCodes.contains(uppercasedToken) {
            return uppercasedToken
        }
        return nil
    }
}

private enum TextNormalizer {
    static func normalizeName(_ rawValue: String) -> String {
        let normalized = normalizeForSearch(rawValue)
        return normalized.replacingOccurrences(of: " ", with: "")
    }

    static func normalizeForSearch(_ rawValue: String) -> String {
        let folded = rawValue
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()

        let transformedScalars = folded.unicodeScalars.map { scalar -> String in
            if CharacterSet.alphanumerics.contains(scalar) {
                return String(scalar)
            }
            return " "
        }

        return transformedScalars
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

private final class XMLTVIndexParserDelegate: NSObject, XMLParserDelegate {
    private var displayNamesByChannelID: [String: Set<String>] = [:]
    private var searchableProgramTextByChannelID: [String: String] = [:]

    private var currentChannelID: String?
    private var currentProgrammeChannelID: String?
    private var activeElement: String?
    private var currentElementText = ""
    private var programmeTitleBuffer: [String] = []
    private var programmeDescriptionBuffer: [String] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "channel":
            currentChannelID = attributeDict["id"]
        case "programme":
            currentProgrammeChannelID = attributeDict["channel"]
            programmeTitleBuffer.removeAll(keepingCapacity: true)
            programmeDescriptionBuffer.removeAll(keepingCapacity: true)
        case "display-name", "title", "desc":
            activeElement = elementName
            currentElementText = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard activeElement != nil else { return }
        currentElementText.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let cleaned = currentElementText.trimmingCharacters(in: .whitespacesAndNewlines)

        if elementName == "display-name",
           activeElement == "display-name",
           let channelID = currentChannelID,
           !cleaned.isEmpty {
            displayNamesByChannelID[channelID, default: []].insert(cleaned)
        } else if elementName == "title",
                  activeElement == "title",
                  !cleaned.isEmpty {
            programmeTitleBuffer.append(cleaned)
        } else if elementName == "desc",
                  activeElement == "desc",
                  !cleaned.isEmpty {
            programmeDescriptionBuffer.append(cleaned)
        }

        if elementName == "channel" {
            currentChannelID = nil
        } else if elementName == "programme" {
            finalizeProgrammeEntry()
            currentProgrammeChannelID = nil
        }

        if elementName == activeElement {
            activeElement = nil
            currentElementText = ""
        }
    }

    func makeIndex() -> EPGIndex {
        var channelIDsByNormalizedName: [String: Set<String>] = [:]
        var countriesByChannelID: [String: Set<String>] = [:]

        for (channelID, displayNames) in displayNamesByChannelID {
            for displayName in displayNames {
                let normalized = TextNormalizer.normalizeName(displayName)
                if !normalized.isEmpty {
                    channelIDsByNormalizedName[normalized, default: []].insert(channelID)
                }

                let countries = CountryExtractor.extractTokens(from: displayName)
                if !countries.isEmpty {
                    countriesByChannelID[channelID, default: []].formUnion(countries)
                }
            }
        }

        return EPGIndex(
            searchableProgramTextByChannelID: searchableProgramTextByChannelID,
            channelIDsByNormalizedName: channelIDsByNormalizedName,
            countriesByChannelID: countriesByChannelID
        )
    }

    private func finalizeProgrammeEntry() {
        guard let channelID = currentProgrammeChannelID else { return }

        let textParts = programmeTitleBuffer + programmeDescriptionBuffer
        guard !textParts.isEmpty else { return }

        let normalizedText = TextNormalizer.normalizeForSearch(textParts.joined(separator: " "))
        guard !normalizedText.isEmpty else { return }

        if let existing = searchableProgramTextByChannelID[channelID] {
            let merged = "\(existing) \(normalizedText)"
            searchableProgramTextByChannelID[channelID] = String(merged.prefix(20_000))
        } else {
            searchableProgramTextByChannelID[channelID] = String(normalizedText.prefix(20_000))
        }
    }
}
