//
//  ContentView.swift
//  IPTV Client
//
//  Created by Albert Monreal on 2/8/26.
//

import AVFoundation
import AVKit
import CoreData
import os
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private extension Color {
    static var appBackground: Color {
        #if os(tvOS)
        Color.black
        #else
        Color(.systemBackground)
        #endif
    }

    static var appSecondaryBackground: Color {
        #if os(tvOS)
        Color(white: 0.16)
        #else
        Color(.secondarySystemBackground)
        #endif
    }

    static var appTertiaryBackground: Color {
        #if os(tvOS)
        Color(white: 0.22)
        #else
        Color(.tertiarySystemBackground)
        #endif
    }
}

struct ContentView: View {
    @Environment(\.managedObjectContext) private var viewContext

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \ProfileEntity.createdAt, ascending: false)],
        animation: .default
    )
    private var profiles: FetchedResults<ProfileEntity>

    @AppStorage("force_dark_mode") private var forceDarkMode = true

    @State private var showAddProfile = false
    @State private var profileToEdit: ProfileEntity?
    @State private var profileToDelete: ProfileEntity?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if profiles.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No profiles yet")
                            .font(.headline)
                        Text("Tap + to import using Xtream, M3U/M3U8, or Stalker portal.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(profiles) { profile in
                    NavigationLink(destination: ContentBrowserView(profile: profile)) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(profile.name)
                                .font(.headline)
                            Text("\(providerDisplayName(for: profile))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    #if !os(tvOS)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            profileToDelete = profile
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }

                        Button {
                            profileToEdit = profile
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                    #endif
                    .contextMenu {
                        Button {
                            profileToEdit = profile
                        } label: {
                            Label("Edit Profile", systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            profileToDelete = profile
                        } label: {
                            Label("Delete Profile", systemImage: "trash")
                        }
                    }
                }
                .onDelete(perform: deleteProfiles)
            }
            .navigationTitle("Profiles")
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button {
                        forceDarkMode.toggle()
                    } label: {
                        Image(systemName: forceDarkMode ? "moon.fill" : "moon")
                    }

                    #if !os(tvOS)
                    EditButton()
                    #endif
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddProfile = true
                    } label: {
                        Label("Add profile", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showAddProfile) {
            AddProfileView(onSave: backUpProfile)
                .environment(\.managedObjectContext, viewContext)
        }
        .sheet(item: $profileToEdit) { profile in
            EditProfileView(profile: profile, onBackup: backUpProfile)
                .environment(\.managedObjectContext, viewContext)
        }
        .confirmationDialog(
            "Delete Profile?",
            isPresented: Binding(
                get: { profileToDelete != nil },
                set: { if !$0 { profileToDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: profileToDelete
        ) { profile in
            Button("Delete \(profile.name)", role: .destructive) {
                deleteProfile(profile)
                profileToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                profileToDelete = nil
            }
        } message: { profile in
            Text("This removes \(profile.name), its saved channels, and its EPG data from this device.")
        }
        .preferredColorScheme(forceDarkMode ? .dark : nil)
        .alert(
            "Error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task {
            await synchronizeProfilesWithCloud()
        }
    }

    private func providerDisplayName(for profile: ProfileEntity) -> String {
        ProfileProviderType(rawValue: profile.providerType)?.displayName ?? "Unknown"
    }

    private func deleteProfiles(offsets: IndexSet) {
        let selectedProfiles = offsets.map { profiles[$0] }
        let profileIDs = selectedProfiles.map(\.id)
        do {
            try IPTVDataStore.deleteProfiles(selectedProfiles, in: viewContext)
            for profileID in profileIDs {
                ContentBootstrapCache.shared.invalidate(profileID)
            }
            for profileID in profileIDs {
                removeProfileFromBackup(profileID)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteProfile(_ profile: ProfileEntity) {
        let profileID = profile.id
        do {
            try IPTVDataStore.deleteProfiles([profile], in: viewContext)
            ContentBootstrapCache.shared.invalidate(profileID)
            removeProfileFromBackup(profileID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func synchronizeProfilesWithCloud() async {
        do {
            let localProfiles = try IPTVDataStore.profileSnapshots(in: viewContext)
            let mergedProfiles = try await ProfileCloudBackup.shared.synchronize(localProfiles: localProfiles)
            try IPTVDataStore.restoreMissingProfiles(from: mergedProfiles, in: viewContext)
        } catch {
            // Local Core Data remains usable when the user is offline or not
            // signed into iCloud, but make the loss of backup protection clear.
            errorMessage = "Profiles are available locally, but iCloud backup could not sync: \(error.localizedDescription)"
        }
    }

    private func backUpProfile(_ profile: ProfileSnapshot) {
        Task {
            do {
                try await ProfileCloudBackup.shared.upsert(profile)
            } catch {
                errorMessage = "The profile was saved locally, but its iCloud backup failed: \(error.localizedDescription)"
            }
        }
    }

    private func removeProfileFromBackup(_ profileID: UUID) {
        Task {
            do {
                try await ProfileCloudBackup.shared.remove(profileID: profileID)
            } catch {
                errorMessage = "The profile was deleted locally, but its iCloud backup could not be updated: \(error.localizedDescription)"
            }
        }
    }
}

private struct AddProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext

    var onSave: (ProfileSnapshot) -> Void = { _ in }

    @State private var providerType: ProfileProviderType = .xtream
    @State private var name = ""
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var playlistURL = ""
    @State private var stalkerMAC = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Provider", selection: $providerType) {
                    ForEach(ProfileProviderType.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)

                TextField("Profile name", text: $name)

                switch providerType {
                case .xtream:
                    TextField("Server", text: $server)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                case .m3u:
                    TextField("Playlist URL", text: $playlistURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                case .stalker:
                    TextField("Portal URL", text: $server)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("MAC Address (00:1A:79:..)", text: $stalkerMAC)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("Add Profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveProfile()
                    }
                    .disabled(!canSave)
                }
            }
        }
        .alert(
            "Could Not Save Profile",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var canSave: Bool {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return false }

        switch providerType {
        case .xtream:
            return !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .m3u:
            return !playlistURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .stalker:
            return !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !stalkerMAC.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func saveProfile() {
        let profile = ProfileEntity(context: viewContext)
        profile.id = UUID()
        profile.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.providerType = providerType.rawValue

        switch providerType {
        case .xtream:
            profile.server = server.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.password = password
            profile.playlistURL = nil
            profile.stalkerMAC = nil

        case .m3u:
            let cleanPlaylist = playlistURL.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.server = cleanPlaylist
            profile.username = ""
            profile.password = ""
            profile.playlistURL = cleanPlaylist
            profile.stalkerMAC = nil

        case .stalker:
            profile.server = server.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.username = ""
            profile.password = ""
            profile.playlistURL = nil
            profile.stalkerMAC = stalkerMAC.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        profile.createdAt = Date()

        do {
            try viewContext.save()
            onSave(ProfileSnapshot(profile: profile))
            dismiss()
        } catch {
            viewContext.rollback()
            errorMessage = error.localizedDescription
        }
    }
}

private struct EditProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext

    let profile: ProfileEntity
    var onSave: () -> Void = {}
    var onBackup: (ProfileSnapshot) -> Void = { _ in }

    @AppStorage("sync_content_live") private var syncLive = true
    @AppStorage("sync_content_movies") private var syncMovies = false
    @AppStorage("sync_content_series") private var syncSeries = false

    @State private var name: String
    @State private var server: String
    @State private var username: String
    @State private var password: String
    @State private var playlistURL: String
    @State private var stalkerMAC: String
    @State private var epgEnabled = true
    @State private var errorMessage: String?

    private var providerType: ProfileProviderType {
        ProfileProviderType(rawValue: profile.providerType) ?? .xtream
    }

    init(
        profile: ProfileEntity,
        onSave: @escaping () -> Void = {},
        onBackup: @escaping (ProfileSnapshot) -> Void = { _ in }
    ) {
        self.profile = profile
        self.onSave = onSave
        self.onBackup = onBackup
        _name = State(initialValue: profile.name)
        _server = State(initialValue: profile.server)
        _username = State(initialValue: profile.username)
        _password = State(initialValue: profile.password)
        _playlistURL = State(initialValue: profile.playlistURL ?? profile.server)
        _stalkerMAC = State(initialValue: profile.stalkerMAC ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    DetailRow(title: "Type", value: providerType.displayName)
                }

                Section("Profile") {
                    TextField("Profile name", text: $name)

                    switch providerType {
                    case .xtream:
                        TextField("Server", text: $server)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                    case .m3u:
                        TextField("Playlist URL", text: $playlistURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                    case .stalker:
                        TextField("Portal URL", text: $server)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("MAC Address (00:1A:79:..)", text: $stalkerMAC)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                Section {
                    Toggle("Live TV", isOn: $syncLive)
                    Toggle("Movies", isOn: $syncMovies)
                    Toggle("Series", isOn: $syncSeries)
                    Toggle("EPG", isOn: $epgEnabled)
                } header: {
                    Text("Content to sync")
                } footer: {
                    Text("Only the enabled types are downloaded when content loads. Turning a type off keeps its existing content but skips re-downloading it.")
                }
            }
            .navigationTitle("Edit Profile")
            #if !os(tvOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveProfile()
                    }
                    .disabled(!canSave)
                }
            }
            .task {
                loadEPGEnabledState()
            }
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var canSave: Bool {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return false }

        switch providerType {
        case .xtream:
            return !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .m3u:
            return !playlistURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .stalker:
            return !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !stalkerMAC.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func saveProfile() {
        profile.name = name.trimmingCharacters(in: .whitespacesAndNewlines)

        switch providerType {
        case .xtream:
            profile.server = server.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.password = password
            profile.playlistURL = nil
            profile.stalkerMAC = nil

        case .m3u:
            let cleanPlaylist = playlistURL.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.server = cleanPlaylist
            profile.username = ""
            profile.password = ""
            profile.playlistURL = cleanPlaylist
            profile.stalkerMAC = nil

        case .stalker:
            profile.server = server.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.username = ""
            profile.password = ""
            profile.playlistURL = nil
            profile.stalkerMAC = stalkerMAC.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        do {
            if let config = try? IPTVDataStore.fetchOrCreateEPGConfig(profileID: profile.id, in: viewContext) {
                config.isEnabled = epgEnabled
            }
            try viewContext.save()
            ContentBootstrapCache.shared.invalidate(profile.id)
            onBackup(ProfileSnapshot(profile: profile))
            onSave()
            dismiss()
        } catch {
            viewContext.rollback()
            errorMessage = error.localizedDescription
        }
    }

    private func loadEPGEnabledState() {
        if let config = try? IPTVDataStore.fetchOrCreateEPGConfig(profileID: profile.id, in: viewContext) {
            epgEnabled = config.isEnabled
        }
    }
}

private struct ProfileDetailView: View {
    let profile: ProfileEntity
    var onProfileUpdated: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext
    @AppStorage("force_dark_mode") private var forceDarkMode = true
    @AppStorage("sync_content_live") private var syncLive = true
    @AppStorage("sync_content_movies") private var syncMovies = false
    @AppStorage("sync_content_series") private var syncSeries = false
    @State private var showEditProfile = false

    var body: some View {
        List {
            Section("Profile") {
                DetailRow(title: "Name", value: profile.name)
                DetailRow(title: "Provider", value: ProfileProviderType(rawValue: profile.providerType)?.displayName ?? "Unknown")
                if let playlist = profile.playlistURL, !playlist.isEmpty {
                    DetailRow(title: "Playlist", value: playlist)
                } else {
                    DetailRow(title: "Server", value: profile.server)
                }
                if !profile.username.isEmpty {
                    DetailRow(title: "Username", value: profile.username)
                }
                if let mac = profile.stalkerMAC, !mac.isEmpty {
                    DetailRow(title: "MAC", value: mac)
                }
            }

            Section {
                Button {
                    showEditProfile = true
                } label: {
                    Label("Edit Profile", systemImage: "pencil")
                }
            }

            Section {
                Toggle("Live TV", isOn: $syncLive)
                Toggle("Movies", isOn: $syncMovies)
                Toggle("Series", isOn: $syncSeries)

                Button {
                    onProfileUpdated()
                    dismiss()
                } label: {
                    Label("Update content now", systemImage: "arrow.clockwise")
                }
            } header: {
                Text("Content to update")
            } footer: {
                Text("Only the enabled types are downloaded when content loads. Turning a type off keeps its existing content but skips re-downloading it.")
            }

            Section {
                Button("Close") {
                    dismiss()
                }
            }

            Section("Appearance") {
                Toggle("Dark mode", isOn: $forceDarkMode)
            }
        }
        .navigationTitle(profile.name)
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    dismiss()
                }
            }
        }
        .sheet(isPresented: $showEditProfile) {
            EditProfileView(
                profile: profile,
                onSave: onProfileUpdated,
                onBackup: { snapshot in
                    Task {
                        try? await ProfileCloudBackup.shared.upsert(snapshot)
                    }
                }
            )
                .environment(\.managedObjectContext, viewContext)
        }
    }
}

private struct DetailRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

#if !os(tvOS)
private struct XMLExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.xml] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
#endif

private struct EPGView: View {
    let profile: ProfileEntity
    var onClose: () -> Void = {}

    @Environment(\.managedObjectContext) private var viewContext

    @State private var isEnabled = true
    @State private var customURL = ""
    @State private var refreshFrequencyHours = 1
    @State private var timeShiftHours = 0
    @State private var lastRefreshAt: Date?
    @State private var statusMessage = "Not downloaded yet"
    @State private var isRefreshing = false
    @State private var isExportingEPG = false
    @State private var showEPGExporter = false
    @State private var epgExportData = Data()
    @State private var epgExportFilename = "epg.xml"
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("EPG")
                    .font(.largeTitle.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer()

                Button {
                    onClose()
                } label: {
                    Label("Close", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                #if !os(tvOS)
                .keyboardShortcut(.cancelAction)
                #endif
                .accessibilityLabel("Close EPG")
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 8)

            Form {
                Section {
                    Toggle("Enabled", isOn: $isEnabled)
                }

                Section("Refresh") {
                    Button {
                        Task {
                            await refreshNow()
                        }
                    } label: {
                        HStack {
                            Text("Refresh now")
                            Spacer()
                            if isRefreshing {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isRefreshing || isExportingEPG || !isEnabled)

                    #if !os(tvOS)
                    Button {
                        Task {
                            await downloadAndExportEPG()
                        }
                    } label: {
                        HStack {
                            Label("Download & Save EPG File", systemImage: "square.and.arrow.down")
                            Spacer()
                            if isExportingEPG {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isRefreshing || isExportingEPG || !isEnabled)

                    Text("Saves the raw XMLTV EPG file using the system save picker.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    #endif

                    if let lastRefreshAt {
                        Text("Last refresh: \(lastRefreshAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    #if os(tvOS)
                    Picker("Refresh frequency", selection: $refreshFrequencyHours) {
                        ForEach(1...24, id: \.self) { hour in
                            Text("\(hour)h").tag(hour)
                        }
                    }
                    Picker("Time shift", selection: $timeShiftHours) {
                        ForEach(-12...12, id: \.self) { hour in
                            Text("\(hour)h").tag(hour)
                        }
                    }
                    #else
                    Stepper("Refresh frequency: \(refreshFrequencyHours)h", value: $refreshFrequencyHours, in: 1...24)
                    Stepper("Time shift: \(timeShiftHours)h", value: $timeShiftHours, in: -12...12)
                    #endif
                }

                Section("Custom URL") {
                    TextField("http://example.com/xmltv.php?...", text: $customURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Button("Clear") {
                        customURL = ""
                        saveConfig(xmlPayload: nil)
                    }
                    .tint(.red)

                    Button("Save") {
                        saveConfig(xmlPayload: nil)
                    }
                }
            }
        }
        .task {
            loadConfig()
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") {
                    onClose()
                }
            }
        }
        #if !os(tvOS)
        .fileExporter(
            isPresented: $showEPGExporter,
            document: XMLExportDocument(data: epgExportData),
            contentType: .xml,
            defaultFilename: epgExportFilename
        ) { result in
            switch result {
            case .success:
                statusMessage = "EPG file saved"
            case let .failure(error):
                errorMessage = error.localizedDescription
            }
        }
        #endif
        .alert(
            "Error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @MainActor
    private func loadConfig() {
        do {
            let config = try IPTVDataStore.fetchOrCreateEPGConfig(profileID: profile.id, in: viewContext)
            isEnabled = config.isEnabled
            customURL = config.customURL ?? ""
            refreshFrequencyHours = max(1, Int(config.refreshFrequencyHours))
            timeShiftHours = Int(config.timeShiftHours)
            lastRefreshAt = config.lastRefreshAt
            statusMessage = config.lastRefreshStatus ?? "Not downloaded yet"
            if config.managedObjectContext?.hasChanges == true {
                try viewContext.save()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func saveConfig(xmlPayload: Data?) {
        do {
            let config = try IPTVDataStore.fetchOrCreateEPGConfig(profileID: profile.id, in: viewContext)
            config.isEnabled = isEnabled
            config.customURL = customURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : customURL.trimmingCharacters(in: .whitespacesAndNewlines)
            config.refreshFrequencyHours = Int16(refreshFrequencyHours)
            config.timeShiftHours = Int16(timeShiftHours)

            if let xmlPayload {
                config.lastXMLData = xmlPayload
                config.lastRefreshAt = Date()
                let sizeText = ByteCountFormatter.string(fromByteCount: Int64(xmlPayload.count), countStyle: .file)
                config.lastRefreshStatus = "Downloaded \(sizeText)"
                lastRefreshAt = config.lastRefreshAt
                statusMessage = config.lastRefreshStatus ?? "Downloaded"
            }

            try viewContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshNow() async {
        guard isEnabled else { return }

        await MainActor.run {
            isRefreshing = true
            saveConfig(xmlPayload: nil)
        }

        let service = IPTVService()
        do {
            let xmlPayload = try await service.downloadEPG(for: profile, customURL: customURL)
            await MainActor.run {
                saveConfig(xmlPayload: xmlPayload)
            }
        } catch {
            await MainActor.run {
                statusMessage = "Refresh failed"
                errorMessage = error.localizedDescription
            }
        }

        await MainActor.run {
            isRefreshing = false
        }
    }

    private func downloadAndExportEPG() async {
        guard isEnabled else { return }

        await MainActor.run {
            isExportingEPG = true
            saveConfig(xmlPayload: nil)
        }

        let service = IPTVService()
        do {
            let xmlPayload = try await service.downloadEPG(for: profile, customURL: customURL)
            await MainActor.run {
                saveConfig(xmlPayload: xmlPayload)
                epgExportData = xmlPayload
                epgExportFilename = defaultEPGFilename()
                isExportingEPG = false
                showEPGExporter = true
            }
        } catch {
            await MainActor.run {
                isExportingEPG = false
                statusMessage = "EPG download failed"
                errorMessage = error.localizedDescription
            }
        }
    }

    private func defaultEPGFilename() -> String {
        let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
        let profileName = profile.name
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = profileName.isEmpty ? "epg" : "\(profileName)-epg"
        return "\(baseName).xml"
    }
}

/// Remembers, per profile, whether a full content sync (Live/Movies/Series
/// fetch + EPG download/index) has already run this app session. Navigating
/// back to the profile list and reopening the same profile recreates
/// ContentBrowserView from scratch, resetting its @State — this cache is what
/// lets that reentry skip straight to loading the already-synced local data
/// instead of repeating the full network sync. It intentionally does not
/// persist across app launches; "Update content now" invalidates it.
@MainActor
private final class ContentBootstrapCache {
    static let shared = ContentBootstrapCache()
    private init() {}

    private var bootstrappedProfileIDs: Set<UUID> = []
    private var epgIndexByProfileID: [UUID: EPGIndex] = [:]
    private var metadataByProfile: [UUID: [IPTVContentType: [ChannelFilterMetadata]]] = [:]

    func hasBootstrapped(_ profileID: UUID) -> Bool {
        bootstrappedProfileIDs.contains(profileID)
    }

    func markBootstrapped(_ profileID: UUID) {
        bootstrappedProfileIDs.insert(profileID)
    }

    func setEPGIndex(_ epgIndex: EPGIndex?, for profileID: UUID) {
        epgIndexByProfileID[profileID] = epgIndex
    }

    func cachedEPGIndex(for profileID: UUID) -> EPGIndex? {
        epgIndexByProfileID[profileID]
    }

    // Per-content-type filter metadata, precomputed during the initial load so
    // switching tabs later reuses it instead of rebuilding (which was the cause
    // of the hang on first tab switch). Survives back/forth within a session
    // because it lives on this singleton, not the recreated view state.
    func metadata(for profileID: UUID, contentType: IPTVContentType) -> [ChannelFilterMetadata]? {
        metadataByProfile[profileID]?[contentType]
    }

    func setMetadata(_ metadata: [ChannelFilterMetadata], for profileID: UUID, contentType: IPTVContentType) {
        metadataByProfile[profileID, default: [:]][contentType] = metadata
    }

    func invalidate(_ profileID: UUID) {
        bootstrappedProfileIDs.remove(profileID)
        epgIndexByProfileID.removeValue(forKey: profileID)
        metadataByProfile.removeValue(forKey: profileID)
    }
}

/// Thread-safe holder for a 0...1 progress fraction, written from a background
/// parsing task and read by a MainActor polling loop, avoiding the need to
/// hop actors on every single progress update.
private final class EPGProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var _fraction: Double = 0

    var fraction: Double {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _fraction
        }
        set {
            lock.lock()
            _fraction = newValue
            lock.unlock()
        }
    }
}

private struct ContentBrowserView: View {
    private enum BrowserSheet: String, Identifiable {
        case downloads
        case epg
        case profile

        var id: String { rawValue }
    }

    private enum FilterSheet: String, Identifiable {
        case country
        case language
        case category

        var id: String { rawValue }
    }

    let profile: ProfileEntity

    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @AppStorage("force_dark_mode") private var forceDarkMode = true
    @AppStorage("favorite_country_tokens") private var favoriteCountryStorage = ""
    @AppStorage("favorite_language_tokens") private var favoriteLanguageStorage = ""
    @AppStorage("sync_content_live") private var syncLive = true
    @AppStorage("sync_content_movies") private var syncMovies = false
    @AppStorage("sync_content_series") private var syncSeries = false

    @AppStorage private var recentChannelsJSON: String

    init(profile: ProfileEntity) {
        self.profile = profile
        _recentChannelsJSON = AppStorage(wrappedValue: "", RecentChannelsStore.key(for: profile.id))
    }

    private var recentChannels: [PlayableChannel] {
        RecentChannelsStore.decode(recentChannelsJSON)
    }

    #if os(tvOS)
    private enum TVFocusTarget: Hashable {
        case tab(IPTVContentType)
        case titleSearchField
    }
    @FocusState private var tvFocusTarget: TVFocusTarget?
    #endif

    @State private var selectedContentType: IPTVContentType = .live
    @State private var channels: [ChannelEntity] = []
    @State private var filteredChannels: [ChannelEntity] = []
    @State private var filteredPlayables: [PlayableChannel] = []
    @State private var visibleChannelLimit = 60
    @State private var channelMetadataCache: [ChannelFilterMetadata] = []
    @State private var isFilteringChannels = false
    @State private var channelFilterGeneration = 0
    @State private var channelFilterTask: Task<Void, Never>?
    @State private var activeDownloadIDs: Set<NSManagedObjectID> = []

    @State private var isInitialLoading = true
    @State private var didBootstrap = false
    @State private var loadingMessage = "Preparing IPTV..."
    @State private var loadingProgress: Double = 0

    @State private var showMenu = false
    @State private var showFilters = true
    @State private var titleQuery = ""
    @State private var debouncedTitleQuery = ""
    @State private var titleSearchDebounceTask: Task<Void, Never>?
    @State private var epgKeywordQuery = ""
    @State private var debouncedEPGKeywordQuery = ""
    @State private var epgSearchDebounceTask: Task<Void, Never>?
    @State private var filterRefreshTask: Task<Void, Never>?
    @State private var selectedCountryToken = "__all__"
    @State private var selectedLanguageToken = "__all_language__"
    @State private var selectedCategoryName = "__all_category__"
    @State private var favoriteCountriesOnly = false
    @State private var favoritesOnly = false
    @State private var downloadedOnly = false
    @State private var epgIndex: EPGIndex?
    @State private var liveCountryOptions: [String] = []
    @State private var languageOptions: [String] = []
    @State private var categoryOptions: [String] = []

    @State private var activeSheet: BrowserSheet?
    @State private var activeFilterSheet: FilterSheet?
    @State private var errorMessage: String?
    @State private var infoMessage: String?

    private let allCountriesToken = "__all__"
    private let allLanguageToken = "__all_language__"
    private let allCategoryToken = "__all_category__"
    // The tvOS focus engine degrades sharply with a large number of
    // simultaneously-focusable cells, so keep the rendered window smaller there
    // and paginate more often. (iOS/macOS handle the bigger window fine.)
    #if os(tvOS)
    private let initialVisibleChannelLimit = 60
    private let visibleChannelIncrement = 60
    #else
    private let initialVisibleChannelLimit = 180
    private let visibleChannelIncrement = 180
    #endif

    private var usesDesktopLayout: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    private var usesWideLayout: Bool {
        if usesDesktopLayout {
            return true
        }
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
        #else
        return false
        #endif
    }

    private var gridColumns: [GridItem] {
        let minimumWidth: CGFloat
        if usesWideLayout {
            minimumWidth = 220
        } else {
            minimumWidth = horizontalSizeClass == .compact ? 150 : 185
        }
        return [GridItem(.adaptive(minimum: minimumWidth), spacing: 12, alignment: .top)]
    }

    private var filterStateToken: String {
        [
            selectedCountryToken,
            selectedLanguageToken,
            selectedCategoryName,
            favoriteCountriesOnly ? "favoriteCountriesOnly" : "",
            favoritesOnly ? "favoritesOnly" : "",
            downloadedOnly ? "downloadedOnly" : "",
            favoriteCountryStorage
        ].joined(separator: "\u{1F}")
    }

    var body: some View {
        ZStack {
            if usesWideLayout {
                wideBrowserLayout
            } else {
                compactBrowserLayout
            }

            if isInitialLoading {
                FunnyLoadingOverlay(message: loadingMessage, progress: loadingProgress)
                    .transition(.opacity)
            }
        }
        .navigationTitle(selectedContentType.displayName)
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showMenu = true
                } label: {
                    Image(systemName: "line.3.horizontal")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showFilters.toggle()
                    }
                } label: {
                    Image(systemName: showFilters ? "magnifyingglass.circle.fill" : "magnifyingglass")
                }
            }
        }
        .confirmationDialog("Menu", isPresented: $showMenu, titleVisibility: .visible) {
            Button("Downloads") {
                activeSheet = .downloads
            }
            Button("EPG") {
                activeSheet = .epg
            }
            Button("Profile Settings") {
                activeSheet = .profile
            }
            Button(forceDarkMode ? "Disable Dark Mode" : "Enable Dark Mode") {
                forceDarkMode.toggle()
            }
            Button("Back to Profiles") {
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $activeSheet) { sheet in
            NavigationStack {
                sheetContent(for: sheet)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        activeSheet = nil
                    }
                }
            }
        }
        .sheet(item: $activeFilterSheet) { sheet in
            NavigationStack {
                filterSheetContent(for: sheet)
            }
        }
        .task {
            await bootstrapContentIfNeeded()
        }
        .onChange(of: selectedContentType) {
            loadChannelsFromStore()
        }
        .onChange(of: titleQuery) {
            scheduleTitleSearchDebounce()
        }
        .onChange(of: epgKeywordQuery) {
            scheduleEPGSearchDebounce()
        }
        .onChange(of: filterStateToken) {
            scheduleFilterRefresh()
        }
        .onDisappear {
            titleSearchDebounceTask?.cancel()
            epgSearchDebounceTask?.cancel()
            filterRefreshTask?.cancel()
            channelFilterTask?.cancel()
        }
        .safeAreaInset(edge: .bottom) {
            if !usesWideLayout {
                bottomContentTabs
            }
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(
            "Info",
            isPresented: Binding(
                get: { infoMessage != nil },
                set: { if !$0 { infoMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(infoMessage ?? "")
        }
    }

    private var compactBrowserLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if showFilters {
                    filterPanel
                }

                channelGridSection
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .disabled(isInitialLoading)
        .blur(radius: isInitialLoading ? 3 : 0)
        #if os(tvOS)
        // Scrolling through a long channel grid can leave the bottom tab bar
        // unreachable via focus navigation alone, so Menu jumps focus there
        // directly instead of the default "pop the whole screen" behavior.
        .onExitCommand {
            tvFocusTarget = .tab(selectedContentType)
        }
        #endif
    }

    private var wideBrowserLayout: some View {
        VStack(alignment: .leading, spacing: 16) {
            desktopContentTabs

            HStack(alignment: .top, spacing: 18) {
                if showFilters {
                    filterSidebar
                }

                ScrollView {
                    channelGridSection
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 20)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .disabled(isInitialLoading)
        .blur(radius: isInitialLoading ? 3 : 0)
    }

    private var filterSidebar: some View {
        filterPanel
            .frame(width: usesDesktopLayout ? 300 : 280, alignment: .topLeading)
    }

    @ViewBuilder
    private var channelGridSection: some View {
        if filteredChannels.isEmpty && isFilteringChannels {
            HStack(spacing: 10) {
                ProgressView()
                Text("Filtering channels…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 30)
            .frame(maxWidth: .infinity, alignment: .center)
        } else if filteredChannels.isEmpty && !isInitialLoading {
            Text("No \(selectedContentType.displayName.lowercased()) found.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 30)
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            if isFilteringChannels {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Updating results…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.bottom, 4)
            }

            let visible = visibleFilteredChannels
            LazyVGrid(columns: gridColumns, spacing: 14) {
                // Identify by the stable, never-nil Core Data objectID rather
                // than ChannelEntity's Identifiable `id` (a non-optional UUID).
                // Stale rows from older builds can have a nil stored id, and
                // force-bridging that nil for identity crashes as soon as a
                // search filters such a row into view.
                ForEach(Array(visible.enumerated()), id: \.element.objectID) { index, channel in
                    channelCell(for: channel)
                        // Load the next page as focus/scroll nears the end of
                        // the current batch. Triggering from the trailing cells
                        // (rather than a spinner placed below a lazy grid) is
                        // reliable on tvOS, where scrolling is focus-driven.
                        .onAppear {
                            if index >= visible.count - gridColumnCount {
                                increaseVisibleChannelLimitIfNeeded()
                            }
                        }
                }
            }

            if visibleChannelLimit < filteredChannels.count {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 18)
                .onAppear {
                    increaseVisibleChannelLimitIfNeeded()
                }
            }
        }
    }

    private var visibleFilteredChannels: [ChannelEntity] {
        Array(filteredChannels.prefix(visibleChannelLimit))
    }

    /// Rough number of columns, used to start paginating a row early.
    private var gridColumnCount: Int {
        if usesWideLayout { return 6 }
        return horizontalSizeClass == .compact ? 3 : 5
    }

    private var desktopContentTabs: some View {
        HStack(spacing: 10) {
            ForEach(IPTVContentType.allCases) { type in
                Button {
                    selectedContentType = type
                } label: {
                    Label(type.displayName, systemImage: iconName(for: type))
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            selectedContentType == type ? Color.accentColor.opacity(0.15) : Color.appSecondaryBackground,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .foregroundStyle(selectedContentType == type ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func channelCell(for channel: ChannelEntity) -> some View {
        NavigationLink {
            destination(for: channel)
        } label: {
            ChannelGridCard(
                title: channel.name,
                imageURL: channel.logoURL,
                contentType: selectedContentType
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                toggleFavorite(channel)
            } label: {
                Label(
                    channel.isFavorite ? "Remove Favorite" : "Add Favorite",
                    systemImage: channel.isFavorite ? "star.slash" : "star"
                )
            }

            if channel.contentType != IPTVContentType.series.rawValue {
                if channel.isDownloaded {
                    Button("Remove Download", role: .destructive) {
                        removeDownload(channel)
                    }
                } else if canDownload(channel) {
                    Button {
                        downloadChannel(channel)
                    } label: {
                        if activeDownloadIDs.contains(channel.objectID) {
                            Label("Downloading...", systemImage: "arrow.down.circle")
                        } else {
                            Label("Download Offline", systemImage: "arrow.down.circle")
                        }
                    }
                    .disabled(activeDownloadIDs.contains(channel.objectID))
                }
            }

            #if !os(tvOS)
            Button {
                UIPasteboard.general.string = channel.streamURL
                infoMessage = "Stream URL copied"
            } label: {
                Label("Copy Stream URL", systemImage: "doc.on.doc")
            }
            #endif
        }
    }

    @ViewBuilder
    private func sheetContent(for sheet: BrowserSheet) -> some View {
        switch sheet {
        case .downloads:
            DownloadsView(profile: profile) {
                activeSheet = nil
            }
        case .epg:
            EPGView(profile: profile) {
                activeSheet = nil
            }
        case .profile:
            ProfileDetailView(profile: profile) {
                Task {
                    await reloadProfileContent()
                }
            }
        }
    }

    private var filterPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField(titlePrompt, text: $titleQuery)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #if os(tvOS)
                    .focused($tvFocusTarget, equals: .titleSearchField)
                    #endif

                if !titleQuery.isEmpty {
                    Button {
                        titleQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Color.appSecondaryBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if selectedContentType == .live {
                HStack(spacing: 8) {
                    Image(systemName: "text.quote")
                        .foregroundStyle(.secondary)

                    TextField("EPG keyword", text: $epgKeywordQuery)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if !epgKeywordQuery.isEmpty {
                        Button {
                            epgKeywordQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .background(Color.appSecondaryBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                countryFilterControl
                favoriteCountriesOnlyControl
            } else {
                languageFilterControl
            }

            categoryFilterControl

            HStack(spacing: 10) {
                filterToggleChip(title: "Favorites", isOn: $favoritesOnly)

                if selectedContentType != .live {
                    filterToggleChip(title: "Downloaded", isOn: $downloadedOnly)
                }

                Button("Clear") {
                    clearFilters()
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.appSecondaryBackground, in: Capsule())
            }

            recentlyWatchedSection
        }
        .padding(12)
        .background(Color.appBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var recentlyWatchedSection: some View {
        let recents = recentChannels
        if !recents.isEmpty {
            Divider()
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 8) {
                Text("Recently Watched")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(recents) { item in
                    NavigationLink {
                        recentChannelDestination(for: item)
                    } label: {
                        HStack(spacing: 10) {
                            ChannelLogoThumbnail(imageURL: item.logoURL, size: 36)
                            Text(item.title)
                                .font(.caption)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var countryFilterControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            filterSelectionButton(
                title: "Country",
                value: selectedCountryToken == allCountriesToken
                    ? "All Countries"
                    : countryDisplayLabel(for: selectedCountryToken),
                subtitle: countryFilterSubtitle
            ) {
                activeFilterSheet = .country
            }

            if !favoriteCountriesInCurrentContext.isEmpty {
                filterTokenRow(
                    title: "Favorite Countries",
                    options: favoriteCountriesInCurrentContext,
                    selection: $selectedCountryToken
                ) { token in
                    countryDisplayLabel(for: token)
                }
            }
        }
    }

    private var favoriteCountriesOnlyControl: some View {
        Button {
            favoriteCountriesOnly.toggle()
            if favoriteCountriesOnly {
                selectedCountryToken = allCountriesToken
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: favoriteCountriesOnly ? "checkmark.square.fill" : "square")
                    .foregroundStyle(favoriteCountriesOnly ? Color.accentColor : Color.secondary)

                Text("Favorite countries only")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                Text("\(favoriteCountriesInCurrentContext.count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.appSecondaryBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(favoriteCountriesInCurrentContext.isEmpty)
        .opacity(favoriteCountriesInCurrentContext.isEmpty ? 0.55 : 1)
    }

    private var languageFilterControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            filterSelectionButton(
                title: "Language",
                value: selectedLanguageToken == allLanguageToken
                    ? "All Languages"
                    : languageDisplayLabel(for: selectedLanguageToken),
                subtitle: languageFilterSubtitle
            ) {
                activeFilterSheet = .language
            }

            if !favoriteLanguagesInCurrentContext.isEmpty {
                filterTokenRow(
                    title: "Favorite Languages",
                    options: favoriteLanguagesInCurrentContext,
                    selection: $selectedLanguageToken
                ) { token in
                    languageDisplayLabel(for: token)
                }
            }
        }
    }

    private var categoryFilterControl: some View {
        filterSelectionButton(
            title: "Category",
            value: selectedCategoryName == allCategoryToken ? "All Categories" : selectedCategoryName,
            subtitle: categoryFilterSubtitle
        ) {
            activeFilterSheet = .category
        }
    }

    private var countryFilterSubtitle: String {
        if liveCountryOptions.isEmpty {
            return "No countries detected in the current results."
        }

        let favoriteCount = favoriteCountriesInCurrentContext.count
        if favoriteCount > 0 {
            return "\(liveCountryOptions.count) available • \(favoriteCount) favorited"
        }

        return "\(liveCountryOptions.count) available"
    }

    private var languageFilterSubtitle: String {
        if languageOptions.isEmpty {
            return "No languages detected in the current results."
        }

        let favoriteCount = favoriteLanguagesInCurrentContext.count
        if favoriteCount > 0 {
            return "\(languageOptions.count) available • \(favoriteCount) favorited"
        }

        return "\(languageOptions.count) available"
    }

    private var categoryFilterSubtitle: String {
        if categoryOptions.isEmpty {
            return "No categories were supplied by the current provider or playlist."
        }

        return "\(categoryOptions.count) available"
    }

    private var favoriteCountriesInCurrentContext: [String] {
        liveCountryOptions
            .filter { favoriteCountryTokens.contains($0) }
            .sorted { countryDisplayLabel(for: $0).localizedCaseInsensitiveCompare(countryDisplayLabel(for: $1)) == .orderedAscending }
    }

    private var favoriteLanguagesInCurrentContext: [String] {
        languageOptions
            .filter { favoriteLanguageTokens.contains($0) }
            .sorted { languageDisplayLabel(for: $0).localizedCaseInsensitiveCompare(languageDisplayLabel(for: $1)) == .orderedAscending }
    }

    private var favoriteCountryTokens: Set<String> {
        Set(
            favoriteCountryStorage
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    private var favoriteLanguageTokens: Set<String> {
        Set(
            favoriteLanguageStorage
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    @ViewBuilder
    private func filterSheetContent(for sheet: FilterSheet) -> some View {
        switch sheet {
        case .country:
            FilterOptionSheet(
                title: "Country",
                allOptionValue: allCountriesToken,
                allOptionTitle: "All Countries",
                allOptionSubtitle: liveCountryOptions.isEmpty ? "No countries detected in the current results." : nil,
                options: countrySheetOptions,
                selectedValue: selectedCountryToken,
                emptyMessage: liveCountryOptions.isEmpty
                    ? "No countries were detected for the loaded channels."
                    : "No countries match your search.",
                favoriteOptionIDs: favoriteCountryTokens,
                onSelect: { selectedCountryToken = $0 },
                onDone: { activeFilterSheet = nil },
                onToggleFavorite: toggleFavoriteCountry
            )
        case .language:
            FilterOptionSheet(
                title: "Language",
                allOptionValue: allLanguageToken,
                allOptionTitle: "All Languages",
                allOptionSubtitle: languageOptions.isEmpty ? "No languages detected in the current results." : nil,
                options: languageSheetOptions,
                selectedValue: selectedLanguageToken,
                emptyMessage: languageOptions.isEmpty
                    ? "No languages were detected for the loaded channels."
                    : "No languages match your search.",
                favoriteOptionIDs: favoriteLanguageTokens,
                onSelect: { selectedLanguageToken = $0 },
                onDone: { activeFilterSheet = nil },
                onToggleFavorite: toggleFavoriteLanguage
            )
        case .category:
            FilterOptionSheet(
                title: "Category",
                allOptionValue: allCategoryToken,
                allOptionTitle: "All Categories",
                allOptionSubtitle: categoryOptions.isEmpty ? "No categories were supplied by the current provider or playlist." : nil,
                options: categorySheetOptions,
                selectedValue: selectedCategoryName,
                emptyMessage: categoryOptions.isEmpty
                    ? "No categories were detected for the loaded channels."
                    : "No categories match your search.",
                onSelect: { selectedCategoryName = $0 },
                onDone: { activeFilterSheet = nil }
            )
        }
    }

    private var countrySheetOptions: [FilterSelectionOption] {
        liveCountryOptions.map { token in
            let displayName = countryDisplayLabel(for: token)
            let subtitle = displayName.caseInsensitiveCompare(token) == .orderedSame ? nil : token
            return FilterSelectionOption(
                id: token,
                title: displayName,
                subtitle: subtitle,
                searchTerms: [token, displayName]
            )
        }
        .sorted { left, right in
            left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
        }
    }

    private var languageSheetOptions: [FilterSelectionOption] {
        languageOptions.map { token in
            let resolvedName = languageDisplayName(for: token)
            let subtitle = resolvedName.caseInsensitiveCompare(token) == .orderedSame ? nil : token
            return FilterSelectionOption(
                id: token,
                title: resolvedName,
                subtitle: subtitle,
                searchTerms: [token, resolvedName]
            )
        }
        .sorted { left, right in
            left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
        }
    }

    private var categorySheetOptions: [FilterSelectionOption] {
        categoryOptions.map { category in
            FilterSelectionOption(
                id: category,
                title: category,
                subtitle: nil,
                searchTerms: [category]
            )
        }
        .sorted { left, right in
            left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
        }
    }

    private func filterSelectionButton(
        title: String,
        value: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(value)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)

                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 12)

                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
            }
            .padding(12)
            .background(Color.appSecondaryBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func filterTokenRow(
        title: String,
        options: [String],
        selection: Binding<String>,
        label: @escaping (String) -> String
    ) -> some View {
        let columns = [GridItem(.adaptive(minimum: usesWideLayout ? 120 : 105), spacing: 8, alignment: .leading)]

        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(options, id: \.self) { option in
                    let selected = selection.wrappedValue == option
                    Button {
                        selection.wrappedValue = option
                    } label: {
                        Text(label(option))
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                selected ? Color.accentColor.opacity(0.18) : Color.appSecondaryBackground,
                                in: Capsule()
                            )
                            .foregroundStyle(selected ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func filterToggleChip(title: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    isOn.wrappedValue ? Color.accentColor.opacity(0.18) : Color.appSecondaryBackground,
                    in: Capsule()
                )
                .foregroundStyle(isOn.wrappedValue ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var bottomContentTabs: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                ForEach(IPTVContentType.allCases) { type in
                    Button {
                        selectedContentType = type
                        #if os(tvOS)
                        // Only pressing a tab (not just navigating focus onto
                        // it) should hand focus off to the content area.
                        tvFocusTarget = .titleSearchField
                        #endif
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: iconName(for: type))
                                .font(.system(size: 16, weight: .semibold))
                            Text(type.displayName)
                                .font(.caption2.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            selectedContentType == type ? Color.accentColor.opacity(0.12) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .foregroundStyle(selectedContentType == type ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                    #if os(tvOS)
                    .focused($tvFocusTarget, equals: .tab(type))
                    #endif
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 6)
            #if os(tvOS)
            // Keeps left/right focus movement confined to the three tab
            // buttons instead of escaping into the content area above;
            // pressing a tab is the only thing that should move focus out.
            .focusSection()
            #endif
        }
        .background(Color.appBackground)
    }

    /// Snapshots the current channels + filter selection on the main thread,
    /// then runs the (heavy) metadata build and filtering on a background task.
    /// Managed objects never leave the main thread — only Sendable value copies
    /// are handed off.
    @MainActor
    private func computeChannelProcessing(rebuildMetadata: Bool) async
        -> (result: ChannelProcessingResult, channels: [ChannelEntity]) {
        let currentChannels = channels
        let rawInfos = currentChannels.map(ChannelRawInfo.init(channel:))
        let cachedMetadata = rebuildMetadata ? nil : channelMetadataCache
        let criteria = makeFilterCriteria()
        let epg = epgIndex

        let result = await Task.detached(priority: .userInitiated) {
            ChannelProcessor.process(
                rawInfos: rawInfos,
                cachedMetadata: cachedMetadata,
                criteria: criteria,
                epgIndex: epg
            )
        }.value

        return (result, currentChannels)
    }

    @MainActor
    private func applyChannelProcessing(_ result: ChannelProcessingResult, channels currentChannels: [ChannelEntity]) {
        channelMetadataCache = result.metadata
        ContentBootstrapCache.shared.setMetadata(result.metadata, for: profile.id, contentType: selectedContentType)
        filteredChannels = result.matchIndices.map { currentChannels[$0] }
        filteredPlayables = result.playables
        visibleChannelLimit = initialVisibleChannelLimit

        if let categoryOptions = result.categoryOptions,
           let languageOptions = result.languageOptions,
           let countryOptions = result.countryOptions {
            applyFilterOptions(
                categories: categoryOptions,
                languages: languageOptions,
                countries: countryOptions
            )
        }
    }

    /// Interactive (fire-and-forget) refilter for keystrokes / filter toggles /
    /// tab switches. Keeps the current list on screen with a spinner until the
    /// background pass finishes, and discards superseded results.
    private func scheduleChannelRefilter(rebuildMetadata: Bool) {
        channelFilterTask?.cancel()

        channelFilterGeneration &+= 1
        let generation = channelFilterGeneration

        isFilteringChannels = true

        channelFilterTask = Task { @MainActor in
            let (result, currentChannels) = await computeChannelProcessing(rebuildMetadata: rebuildMetadata)
            guard !Task.isCancelled, generation == channelFilterGeneration else { return }
            applyChannelProcessing(result, channels: currentChannels)
            isFilteringChannels = false
        }
    }

    private func makeFilterCriteria() -> ChannelFilterCriteria {
        let cleanTitle = debouncedTitleQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanEPGKeyword = debouncedEPGKeywordQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return ChannelFilterCriteria(
            cleanTitle: cleanTitle,
            normalizedTitle: cleanTitle.localizedLowercase,
            cleanEPGKeyword: cleanEPGKeyword,
            favoritesOnly: favoritesOnly,
            selectedCategoryName: selectedCategoryName,
            allCategoryToken: allCategoryToken,
            selectedLanguageToken: selectedLanguageToken,
            allLanguageToken: allLanguageToken,
            downloadedOnly: downloadedOnly,
            isLive: selectedContentType == .live,
            favoriteCountriesOnly: favoriteCountriesOnly,
            selectedCountryToken: selectedCountryToken,
            allCountriesToken: allCountriesToken,
            favoriteCountryTokens: favoriteCountryTokens,
            fallbackContentTypeRaw: selectedContentType.rawValue
        )
    }

    /// Applies option lists produced by the background pass and reconciles any
    /// now-invalid selections (sorting by display label is cheap here — the
    /// option lists are small).
    private func applyFilterOptions(categories: [String], languages: [String], countries: [String]) {
        categoryOptions = categories.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        if selectedCategoryName != allCategoryToken, !categoryOptions.contains(selectedCategoryName) {
            selectedCategoryName = allCategoryToken
        }

        languageOptions = languages.sorted {
            languageDisplayLabel(for: $0).localizedCaseInsensitiveCompare(languageDisplayLabel(for: $1)) == .orderedAscending
        }
        if selectedLanguageToken != allLanguageToken, !languageOptions.contains(selectedLanguageToken) {
            selectedLanguageToken = allLanguageToken
        }

        if selectedContentType == .live {
            liveCountryOptions = countries.sorted {
                countryDisplayLabel(for: $0).localizedCaseInsensitiveCompare(countryDisplayLabel(for: $1)) == .orderedAscending
            }
            if selectedCountryToken != allCountriesToken, !liveCountryOptions.contains(selectedCountryToken) {
                selectedCountryToken = allCountriesToken
            }
        } else {
            liveCountryOptions = []
            selectedCountryToken = allCountriesToken
        }
    }

    private func increaseVisibleChannelLimitIfNeeded() {
        guard visibleChannelLimit < filteredChannels.count else { return }
        visibleChannelLimit = min(filteredChannels.count, visibleChannelLimit + visibleChannelIncrement)
    }

    @ViewBuilder
    private func destination(for channel: ChannelEntity) -> some View {
        if channel.contentType == IPTVContentType.series.rawValue,
           let seriesID = channel.externalID,
           !seriesID.isEmpty {
            SeriesEpisodesView(profile: profile, seriesID: seriesID, title: channel.name)
        } else {
            PlayerView(
                title: channel.name,
                streamURL: channel.streamURL,
                localFilePath: channel.localFilePath,
                profileID: profile.id,
                contentType: IPTVContentType(rawValue: channel.contentType) ?? selectedContentType,
                playlist: filteredPlayables
            )
        }
    }

    @ViewBuilder
    private func recentChannelDestination(for item: PlayableChannel) -> some View {
        PlayerView(
            title: item.title,
            streamURL: item.streamURL,
            localFilePath: item.localFilePath,
            profileID: profile.id,
            contentType: item.contentType ?? selectedContentType,
            playlist: filteredPlayables
        )
    }

    /// Loads the current content type's channels for display. If that type's
    /// metadata was already precomputed (during the initial load, or a previous
    /// visit this session), it's reused so the switch is instant; otherwise it
    /// is built off the main thread with a spinner.
    @MainActor
    private func loadChannelsFromStore() {
        do {
            channels = try IPTVDataStore.fetchChannels(
                profileID: profile.id,
                contentType: selectedContentType,
                in: viewContext
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        visibleChannelLimit = initialVisibleChannelLimit

        let cached = ContentBootstrapCache.shared.metadata(for: profile.id, contentType: selectedContentType)
        if let cached, cached.count == channels.count {
            channelMetadataCache = cached
            scheduleChannelRefilter(rebuildMetadata: false)
        } else {
            scheduleChannelRefilter(rebuildMetadata: true)
        }
    }

    // Loads EVERYTHING a profile needs up front, under one loading screen:
    // channels, the EPG index, filter metadata, and the first screen of logos.
    // When this returns and the overlay is dismissed, there is no remaining
    // background work — browsing, searching, and scrolling operate purely on
    // data already in memory, so the UI stays fast.
    @MainActor
    private func bootstrapContentIfNeeded() async {
        guard !didBootstrap else {
            // View reappeared (e.g. returning from the player). Everything is
            // already in @State; nothing to reload.
            isInitialLoading = false
            return
        }

        // Returning to this profile within the same app session: channels are
        // in the store and the EPG index is still in memory, so just rebuild
        // the in-memory view state (fast) without any network or re-index.
        if ContentBootstrapCache.shared.hasBootstrapped(profile.id) {
            didBootstrap = true
            isInitialLoading = true
            loadingMessage = "Preparing channels…"
            loadingProgress = 0.5
            epgIndex = ContentBootstrapCache.shared.cachedEPGIndex(for: profile.id)
            await loadChannelsFromStoreBlocking()
            isInitialLoading = false
            return
        }

        didBootstrap = true
        isInitialLoading = true
        loadingProgress = 0
        loadingMessage = "Preparing…"

        let syncTypes = IPTVContentType.allCases.filter(shouldSyncOnLoad)
        let epgEnabled = (try? IPTVDataStore.fetchOrCreateEPGConfig(profileID: profile.id, in: viewContext))?.isEnabled ?? false

        // Only hit the network if this profile has never been synced to disk.
        // Once synced, "Update content now" is the way to refresh — we don't
        // silently re-download on every launch.
        let hasLocalChannels = ((try? IPTVDataStore.fetchChannels(
            profileID: profile.id,
            contentType: selectedContentType,
            in: viewContext
        ).count) ?? 0) > 0
        let willFetch = !hasLocalChannels

        let service = IPTVService()
        var transientError: String?

        // Progress bands: network fetch 0→0.45, EPG 0.45→0.85, finalize 0.85→1.
        let fetchBandEnd = willFetch ? 0.45 : 0.0
        let epgBandStart = fetchBandEnd
        let epgBandEnd = epgEnabled ? 0.85 : epgBandStart

        if willFetch {
            for (index, type) in syncTypes.enumerated() {
                loadingMessage = "Loading \(type.displayName)…"
                do {
                    let payloads = try await service.fetchChannels(for: profile, contentType: type)
                    try IPTVDataStore.replaceChannels(
                        profileID: profile.id,
                        contentType: type,
                        channels: payloads,
                        in: viewContext
                    )
                } catch let error as IPTVServiceError {
                    switch error {
                    case .unsupportedProviderForContent, .noChannelsReturned:
                        break
                    default:
                        transientError = error.localizedDescription
                    }
                } catch {
                    transientError = error.localizedDescription
                }
                loadingProgress = fetchBandEnd * Double(index + 1) / Double(max(syncTypes.count, 1))
            }
        }

        // EPG download + index — done now, under the overlay, so nothing heavy
        // runs once the user is browsing.
        if epgEnabled {
            loadingMessage = "Downloading EPG…"
            await refreshEPGDuringBootstrapIfPossible(using: service)
            loadingMessage = "Indexing EPG…"
            await buildEPGIndexBlocking(bandStart: epgBandStart, bandEnd: epgBandEnd)
        } else {
            epgIndex = nil
        }

        // Precompute filter metadata for EVERY enabled content type now, so
        // switching tabs later is instant rather than triggering a fresh
        // (heavy) metadata build. The current tab also gets its first screen
        // of logos warmed.
        loadingMessage = "Preparing channels…"
        loadingProgress = max(loadingProgress, epgBandEnd)
        let finalizeBand = 1.0 - epgBandEnd
        for (index, type) in syncTypes.enumerated() {
            await precomputeMetadata(for: type, prefetchLogos: type == selectedContentType)
            loadingProgress = epgBandEnd + finalizeBand * Double(index + 1) / Double(max(syncTypes.count, 1)) * 0.9
        }

        // Load the current tab for display (reuses the metadata just built).
        await loadChannelsFromStoreBlocking()

        if channels.isEmpty, let transientError {
            errorMessage = transientError
        }
        ContentBootstrapCache.shared.markBootstrapped(profile.id)
        ContentBootstrapCache.shared.setEPGIndex(epgIndex, for: profile.id)
        loadingProgress = 1
        isInitialLoading = false
    }

    /// Fetches the current content type's channels from the store and applies
    /// the filter, awaiting completion (used under the loading overlay during
    /// bootstrap). Reuses precomputed metadata when available.
    @MainActor
    private func loadChannelsFromStoreBlocking() async {
        do {
            channels = try IPTVDataStore.fetchChannels(
                profileID: profile.id,
                contentType: selectedContentType,
                in: viewContext
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        visibleChannelLimit = initialVisibleChannelLimit

        let cached = ContentBootstrapCache.shared.metadata(for: profile.id, contentType: selectedContentType)
        let reuse = cached?.count == channels.count
        if reuse, let cached {
            channelMetadataCache = cached
        }
        let (result, currentChannels) = await computeChannelProcessing(rebuildMetadata: !reuse)
        applyChannelProcessing(result, channels: currentChannels)
    }

    /// Builds (and caches) the filter metadata for a content type without
    /// displaying it, so a later tab switch to it is instant. Optionally warms
    /// the first screen of that type's logos too.
    @MainActor
    private func precomputeMetadata(for type: IPTVContentType, prefetchLogos: Bool) async {
        let typeChannels: [ChannelEntity]
        do {
            typeChannels = try IPTVDataStore.fetchChannels(
                profileID: profile.id,
                contentType: type,
                in: viewContext
            )
        } catch {
            return
        }

        if ContentBootstrapCache.shared.metadata(for: profile.id, contentType: type)?.count != typeChannels.count {
            let rawInfos = typeChannels.map(ChannelRawInfo.init(channel:))
            let epg = epgIndex
            let metadata = await Task.detached(priority: .userInitiated) {
                ChannelProcessor.buildMetadata(rawInfos: rawInfos, epgIndex: epg)
            }.value
            ContentBootstrapCache.shared.setMetadata(metadata, for: profile.id, contentType: type)
        }

        if prefetchLogos {
            let urls = typeChannels.prefix(initialVisibleChannelLimit)
                .compactMap { $0.logoURL.flatMap(URL.init(string:)) }
            if !urls.isEmpty {
                await ChannelImageLoader.shared.prefetch(urls: urls, maxPixelSize: 208)
            }
        }
    }

    /// Downloads (if needed) and indexes the EPG synchronously as part of the
    /// startup load, mapping index progress into the given overlay band.
    @MainActor
    private func buildEPGIndexBlocking(bandStart: Double, bandEnd: Double) async {
        let xmlData: Data? = {
            guard let config = try? IPTVDataStore.fetchOrCreateEPGConfig(profileID: profile.id, in: viewContext),
                  config.isEnabled else { return nil }
            return config.lastXMLData
        }()

        guard let xmlData, !xmlData.isEmpty else {
            epgIndex = nil
            loadingProgress = bandEnd
            return
        }

        let reporter = EPGProgressReporter()
        let pollTask = Task { @MainActor in
            while !Task.isCancelled {
                loadingProgress = bandStart + (bandEnd - bandStart) * reporter.fraction
                try? await Task.sleep(for: .milliseconds(150))
            }
        }

        let builtIndex = await Task.detached(priority: .userInitiated) {
            EPGIndex.build(from: xmlData) { fraction in
                reporter.fraction = fraction
            }
        }.value

        pollTask.cancel()
        epgIndex = builtIndex
        loadingProgress = bandEnd
    }

    private func shouldSyncOnLoad(_ type: IPTVContentType) -> Bool {
        switch type {
        case .live:
            return syncLive
        case .movies:
            return syncMovies
        case .series:
            return syncSeries
        }
    }

    private func reloadProfileContent() async {
        await MainActor.run {
            channels = []
            filteredChannels = []
            filteredPlayables = []
            visibleChannelLimit = initialVisibleChannelLimit
            channelMetadataCache = []
            didBootstrap = false
            isInitialLoading = true
            loadingMessage = "Updating profile..."
            ContentBootstrapCache.shared.invalidate(profile.id)
        }

        await bootstrapContentIfNeeded()
    }

    private func refreshEPGDuringBootstrapIfPossible(using service: IPTVService) async {
        let epgConfig = await MainActor.run { () -> (isEnabled: Bool, customURL: String?)? in
            do {
                let config = try IPTVDataStore.fetchOrCreateEPGConfig(profileID: profile.id, in: viewContext)
                return (config.isEnabled, config.customURL)
            } catch {
                return nil
            }
        }

        guard let epgConfig, epgConfig.isEnabled else { return }

        do {
            let xmlData = try await service.downloadEPG(for: profile, customURL: epgConfig.customURL)
            await MainActor.run {
                do {
                    let config = try IPTVDataStore.fetchOrCreateEPGConfig(profileID: profile.id, in: viewContext)
                    config.lastXMLData = xmlData
                    config.lastRefreshAt = Date()
                    config.lastRefreshStatus = "Auto-refreshed"
                    try viewContext.save()
                } catch {
                    // EPG is optional for playback, so avoid blocking the main flow.
                }
            }
        } catch {
            // Ignore EPG bootstrap failures; channel browsing should still continue.
        }
    }

    @MainActor
    private func countryDisplayLabel(for token: String) -> String {
        CountryExtractor.displayLabel(for: token)
    }

    private func languageDisplayLabel(for token: String) -> String {
        let resolvedName = languageDisplayName(for: token)
        if resolvedName.caseInsensitiveCompare(token) == .orderedSame {
            return token
        }
        return "\(resolvedName) (\(token))"
    }

    private func languageDisplayName(for token: String) -> String {
        let upper = token.uppercased()
        let commonNames: [String: String] = [
            "AR": "Arabic",
            "DE": "German",
            "EN": "English",
            "ES": "Spanish",
            "FR": "French",
            "HI": "Hindi",
            "IT": "Italian",
            "JA": "Japanese",
            "KO": "Korean",
            "NL": "Dutch",
            "PL": "Polish",
            "PT": "Portuguese",
            "RU": "Russian",
            "SV": "Swedish",
            "TR": "Turkish",
            "ZH": "Chinese"
        ]

        if let commonName = commonNames[upper] {
            return commonName
        }

        if let localized = Locale.current.localizedString(forLanguageCode: upper.lowercased()) {
            return localized.capitalized(with: Locale.current)
        }

        return upper
    }

    private func scheduleTitleSearchDebounce() {
        titleSearchDebounceTask?.cancel()
        let pendingQuery = titleQuery
        if pendingQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            debouncedTitleQuery = ""
            scheduleChannelRefilter(rebuildMetadata: false)
            return
        }

        titleSearchDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                debouncedTitleQuery = pendingQuery
                scheduleChannelRefilter(rebuildMetadata: false)
            }
        }
    }

    private func scheduleEPGSearchDebounce() {
        epgSearchDebounceTask?.cancel()
        let pendingQuery = epgKeywordQuery
        if pendingQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            debouncedEPGKeywordQuery = ""
            scheduleChannelRefilter(rebuildMetadata: false)
            return
        }

        epgSearchDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                debouncedEPGKeywordQuery = pendingQuery
                scheduleChannelRefilter(rebuildMetadata: false)
            }
        }
    }

    private func scheduleFilterRefresh() {
        filterRefreshTask?.cancel()
        filterRefreshTask = Task {
            try? await Task.sleep(nanoseconds: 75_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                scheduleChannelRefilter(rebuildMetadata: false)
            }
        }
    }

    private var titlePrompt: String {
        switch selectedContentType {
        case .live:
            return "Channel name"
        case .movies:
            return "Movie title"
        case .series:
            return "Series title"
        }
    }

    private func iconName(for type: IPTVContentType) -> String {
        switch type {
        case .live:
            return "tv"
        case .movies:
            return "film"
        case .series:
            return "rectangle.stack.person.crop"
        }
    }

    private func clearFilters() {
        titleSearchDebounceTask?.cancel()
        epgSearchDebounceTask?.cancel()
        filterRefreshTask?.cancel()
        titleQuery = ""
        debouncedTitleQuery = ""
        epgKeywordQuery = ""
        debouncedEPGKeywordQuery = ""
        selectedCountryToken = allCountriesToken
        selectedLanguageToken = allLanguageToken
        selectedCategoryName = allCategoryToken
        favoriteCountriesOnly = false
        favoritesOnly = false
        downloadedOnly = false
        scheduleChannelRefilter(rebuildMetadata: false)
    }

    private func toggleFavoriteCountry(_ token: String) {
        var updatedFavorites = favoriteCountryTokens
        if updatedFavorites.contains(token) {
            updatedFavorites.remove(token)
        } else {
            updatedFavorites.insert(token)
        }

        favoriteCountryStorage = updatedFavorites
            .sorted { countryDisplayLabel(for: $0).localizedCaseInsensitiveCompare(countryDisplayLabel(for: $1)) == .orderedAscending }
            .joined(separator: "\n")
    }

    private func toggleFavoriteLanguage(_ token: String) {
        var updatedFavorites = favoriteLanguageTokens
        if updatedFavorites.contains(token) {
            updatedFavorites.remove(token)
        } else {
            updatedFavorites.insert(token)
        }

        favoriteLanguageStorage = updatedFavorites
            .sorted { languageDisplayLabel(for: $0).localizedCaseInsensitiveCompare(languageDisplayLabel(for: $1)) == .orderedAscending }
            .joined(separator: "\n")
    }

    @MainActor
    private func toggleFavorite(_ channel: ChannelEntity) {
        do {
            // Favorite status isn't part of ChannelFilterMetadata or the filter
            // option lists, so a full loadChannelsFromStore() (Core Data
            // re-fetch + metadata rebuild + filter-options rebuild over every
            // channel) is unnecessary here and was the actual cause of the
            // multi-second "hang" on a single star tap. Only the visible
            // filtered list needs recomputing (e.g. to drop the channel when
            // "Favorites only" is active).
            try IPTVDataStore.setFavorite(!channel.isFavorite, for: channel, in: viewContext)
            scheduleChannelRefilter(rebuildMetadata: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func canDownload(_ channel: ChannelEntity) -> Bool {
        if channel.contentType == IPTVContentType.live.rawValue {
            return false
        }
        if channel.streamURL.hasPrefix("series://") {
            return false
        }
        return URL(string: channel.streamURL) != nil
    }

    private func downloadChannel(_ channel: ChannelEntity) {
        guard canDownload(channel) else {
            errorMessage = "Offline download is available for movies and episodes in this build."
            return
        }

        let channelObjectID = channel.objectID
        let streamURLString = channel.streamURL
        let suggestedName = channel.name

        activeDownloadIDs.insert(channelObjectID)

        Task {
            do {
                guard let streamURL = URL(string: streamURLString) else {
                    throw IPTVServiceError.malformedURL(streamURLString)
                }
                let localPath = try await OfflineStorage.download(from: streamURL, suggestedName: suggestedName)

                await MainActor.run {
                    defer { activeDownloadIDs.remove(channelObjectID) }
                    do {
                        guard let localChannel = try viewContext.existingObject(with: channelObjectID) as? ChannelEntity else {
                            return
                        }
                        try IPTVDataStore.setDownloadedState(
                            for: localChannel,
                            isDownloaded: true,
                            localFilePath: localPath,
                            in: viewContext
                        )
                        loadChannelsFromStore()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            } catch {
                await MainActor.run {
                    activeDownloadIDs.remove(channelObjectID)
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    @MainActor
    private func removeDownload(_ channel: ChannelEntity) {
        if let path = channel.localFilePath {
            try? FileManager.default.removeItem(atPath: path)
        }

        do {
            try IPTVDataStore.setDownloadedState(
                for: channel,
                isDownloaded: false,
                localFilePath: nil,
                in: viewContext
            )
            loadChannelsFromStore()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct FilterSelectionOption: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String?
    let searchTerms: [String]
}

private struct FilterOptionSheet: View {
    let title: String
    let allOptionValue: String
    let allOptionTitle: String
    let allOptionSubtitle: String?
    let options: [FilterSelectionOption]
    let selectedValue: String
    let emptyMessage: String
    var favoriteOptionIDs: Set<String> = []
    let onSelect: (String) -> Void
    let onDone: () -> Void
    var onToggleFavorite: ((String) -> Void)?

    @State private var searchText = ""

    private var filteredOptions: [FilterSelectionOption] {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return options
        }

        return options.filter { option in
            option.searchTerms.contains { $0.localizedCaseInsensitiveContains(trimmedQuery) }
        }
    }

    private var favoriteOptions: [FilterSelectionOption] {
        filteredOptions.filter { favoriteOptionIDs.contains($0.id) }
    }

    private var remainingOptions: [FilterSelectionOption] {
        filteredOptions.filter { !favoriteOptionIDs.contains($0.id) }
    }

    var body: some View {
        List {
            Section {
                optionRow(
                    value: allOptionValue,
                    title: allOptionTitle,
                    subtitle: allOptionSubtitle,
                    isSelected: selectedValue == allOptionValue,
                    isFavorite: false,
                    canFavorite: false
                )
            }

            if !favoriteOptions.isEmpty {
                Section("Favorites") {
                    ForEach(favoriteOptions) { option in
                        optionRow(
                            value: option.id,
                            title: option.title,
                            subtitle: option.subtitle,
                            isSelected: selectedValue == option.id,
                            isFavorite: true,
                            canFavorite: onToggleFavorite != nil
                        )
                    }
                }
            }

            if !remainingOptions.isEmpty {
                Section(favoriteOptions.isEmpty ? "Available" : "All") {
                    ForEach(remainingOptions) { option in
                        optionRow(
                            value: option.id,
                            title: option.title,
                            subtitle: option.subtitle,
                            isSelected: selectedValue == option.id,
                            isFavorite: favoriteOptionIDs.contains(option.id),
                            canFavorite: onToggleFavorite != nil
                        )
                    }
                }
            } else if favoriteOptions.isEmpty {
                Section("Available") {
                    Text(emptyMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(title)
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .searchable(text: $searchText, prompt: "Search \(title.lowercased())")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    onDone()
                }
            }
        }
    }

    private func optionRow(
        value: String,
        title: String,
        subtitle: String?,
        isSelected: Bool,
        isFavorite: Bool,
        canFavorite: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Button {
                onSelect(value)
                onDone()
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .foregroundStyle(.primary)

                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 12)

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.headline)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .buttonStyle(.plain)

            if canFavorite {
                Button {
                    onToggleFavorite?(value)
                } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ChannelGridCard: View {
    let title: String
    let imageURL: String?
    let contentType: IPTVContentType

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let imageURL, let url = URL(string: imageURL) {
                    CachedAsyncImage(url: url, maxPixelSize: imageHeight * 2) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: contentType == .live ? .fit : .fill)
                            .padding(contentType == .live ? 10 : 0)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } placeholder: {
                        placeholder
                    }
                } else {
                    placeholder
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: imageHeight)
            .background(Color.appTertiaryBackground)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )

            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var imageHeight: CGFloat {
        contentType == .live ? 104 : 170
    }

    private var placeholder: some View {
        ZStack {
            Color.gray.opacity(0.2)
            Image(systemName: contentType == .live ? "tv" : "film")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }
}

/// Small square channel logo used in recently-watched lists.
private struct ChannelLogoThumbnail: View {
    let imageURL: String?
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let imageURL, let url = URL(string: imageURL) {
                CachedAsyncImage(url: url, maxPixelSize: size * 2) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(4)
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .background(Color.appTertiaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            Color.gray.opacity(0.2)
            Image(systemName: "tv")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct FunnyLoadingOverlay: View {
    let message: String
    var progress: Double = 0

    @State private var rotateDish = false
    @State private var bouncePopcorn = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                HStack(spacing: 18) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.cyan)
                        .rotationEffect(.degrees(rotateDish ? 360 : 0))

                    Text("🍿")
                        .font(.system(size: 44))
                        .offset(y: bouncePopcorn ? -8 : 8)
                }

                Text(message)
                    .font(.headline)
                    .foregroundStyle(.white)

                ProgressView(value: progress)
                    .tint(.cyan)
                    .frame(width: 220)

                Text("Gathering channels from deep space...")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 28)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                rotateDish = true
            }
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                bouncePopcorn = true
            }
        }
    }
}

private struct SeriesEpisodesView: View {
    let profile: ProfileEntity
    let seriesID: String
    let title: String

    @Environment(\.managedObjectContext) private var viewContext

    @State private var episodes: [ChannelPayload] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var activeDownloadIDs: Set<Int64> = []
    @State private var downloadedEpisodeIDs: Set<Int64> = []
    @State private var errorMessage: String?
    @State private var infoMessage: String?

    var body: some View {
        List {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }

            ForEach(filteredEpisodes, id: \.streamID) { episode in
                HStack(spacing: 10) {
                    NavigationLink {
                        PlayerView(
                            title: episode.name,
                            streamURL: episode.streamURL,
                            localFilePath: nil,
                            profileID: profile.id,
                            contentType: .series
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(episode.name)
                            if let category = episode.categoryName {
                                Text(category)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 8)

                    Menu {
                        if downloadedEpisodeIDs.contains(episode.streamID) {
                            Button("Remove Download", role: .destructive) {
                                removeEpisodeDownload(episode)
                            }
                        } else if canDownloadEpisode(episode) {
                            Button {
                                downloadEpisode(episode)
                            } label: {
                                if activeDownloadIDs.contains(episode.streamID) {
                                    Label("Downloading...", systemImage: "arrow.down.circle")
                                } else {
                                    Label("Download Offline", systemImage: "arrow.down.circle")
                                }
                            }
                            .disabled(activeDownloadIDs.contains(episode.streamID))
                        }

                        #if !os(tvOS)
                        Button {
                            UIPasteboard.general.string = episode.streamURL
                            infoMessage = "Stream URL copied"
                        } label: {
                            Label("Copy Stream URL", systemImage: "doc.on.doc")
                        }
                        #endif
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !isLoading && filteredEpisodes.isEmpty {
                Text("No episodes found.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(title)
        .searchable(text: $searchText, prompt: "Search episode")
        .task {
            await loadEpisodes()
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(
            "Info",
            isPresented: Binding(
                get: { infoMessage != nil },
                set: { if !$0 { infoMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(infoMessage ?? "")
        }
    }

    private var filteredEpisodes: [ChannelPayload] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return episodes }

        return episodes.filter {
            $0.name.localizedCaseInsensitiveContains(query)
            || ($0.categoryName?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func loadEpisodes() async {
        await MainActor.run {
            isLoading = true
        }

        let service = IPTVService()
        do {
            let loadedEpisodes = try await service.fetchSeriesEpisodes(for: profile, seriesID: seriesID)
            await MainActor.run {
                episodes = loadedEpisodes
                loadDownloadedEpisodeIDs()
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }

        await MainActor.run {
            isLoading = false
        }
    }

    private func canDownloadEpisode(_ episode: ChannelPayload) -> Bool {
        URL(string: episode.streamURL) != nil
    }

    private func downloadEpisode(_ episode: ChannelPayload) {
        guard canDownloadEpisode(episode) else {
            errorMessage = "Invalid episode URL."
            return
        }

        guard let remoteURL = URL(string: episode.streamURL) else {
            errorMessage = "Invalid episode URL."
            return
        }

        activeDownloadIDs.insert(episode.streamID)
        Task {
            do {
                let localPath = try await OfflineStorage.download(from: remoteURL, suggestedName: episode.name)
                await MainActor.run {
                    defer { activeDownloadIDs.remove(episode.streamID) }
                    do {
                        try IPTVDataStore.upsertDownloadedItem(
                            profileID: profile.id,
                            payload: episode,
                            localFilePath: localPath,
                            in: viewContext
                        )
                        downloadedEpisodeIDs.insert(episode.streamID)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            } catch {
                await MainActor.run {
                    activeDownloadIDs.remove(episode.streamID)
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    @MainActor
    private func removeEpisodeDownload(_ episode: ChannelPayload) {
        do {
            let existingDownloads = try IPTVDataStore.fetchDownloadedChannels(profileID: profile.id, in: viewContext)
            guard let downloaded = existingDownloads.first(where: {
                $0.streamID == episode.streamID && $0.contentType == IPTVContentType.series.rawValue
            }) else {
                downloadedEpisodeIDs.remove(episode.streamID)
                return
            }

            if let path = downloaded.localFilePath {
                try? FileManager.default.removeItem(atPath: path)
            }

            try IPTVDataStore.setDownloadedState(
                for: downloaded,
                isDownloaded: false,
                localFilePath: nil,
                in: viewContext
            )
            downloadedEpisodeIDs.remove(episode.streamID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func loadDownloadedEpisodeIDs() {
        do {
            let existingDownloads = try IPTVDataStore.fetchDownloadedChannels(profileID: profile.id, in: viewContext)
            downloadedEpisodeIDs = Set(
                existingDownloads
                    .filter { $0.contentType == IPTVContentType.series.rawValue }
                    .map(\.streamID)
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct DownloadsView: View {
    let profile: ProfileEntity
    var onClose: () -> Void = {}

    @Environment(\.managedObjectContext) private var viewContext
    @State private var channels: [ChannelEntity] = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("Downloads")
                    .font(.largeTitle.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer()

                Button {
                    onClose()
                } label: {
                    Label("Close", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                #if !os(tvOS)
                .keyboardShortcut(.cancelAction)
                #endif
                .accessibilityLabel("Close Downloads")
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 8)

            List {
                if channels.isEmpty {
                    Text("No offline videos yet.")
                        .foregroundStyle(.secondary)
                }

                ForEach(channels, id: \.objectID) { channel in
                    NavigationLink {
                        PlayerView(
                            title: channel.name,
                            streamURL: channel.streamURL,
                            localFilePath: channel.localFilePath,
                            profileID: profile.id,
                            contentType: IPTVContentType(rawValue: channel.contentType)
                        )
                    } label: {
                        HStack(spacing: 12) {
                            ChannelLogoView(urlString: channel.logoURL, size: 42, circular: true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(channel.name)
                                Text(channel.contentType.capitalized)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    #if !os(tvOS)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button("Delete", role: .destructive) {
                            removeOffline(channel)
                        }
                    }
                    #else
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            removeOffline(channel)
                        }
                    }
                    #endif
                }
            }
            #if os(tvOS)
            .listStyle(.plain)
            #else
            .listStyle(.insetGrouped)
            #endif
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") {
                    onClose()
                }
            }
        }
        .task {
            loadDownloads()
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @MainActor
    private func loadDownloads() {
        do {
            channels = try IPTVDataStore.fetchDownloadedChannels(profileID: profile.id, in: viewContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func removeOffline(_ channel: ChannelEntity) {
        if let path = channel.localFilePath {
            try? FileManager.default.removeItem(atPath: path)
        }

        do {
            try IPTVDataStore.setDownloadedState(
                for: channel,
                isDownloaded: false,
                localFilePath: nil,
                in: viewContext
            )
            loadDownloads()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A lightweight, Codable snapshot of a channel used both for in-player
/// next/previous navigation and for persisting the recently-watched list.
/// Kept separate from `ChannelEntity` so it can cross view boundaries and be
/// stored without touching Core Data.
struct PlayableChannel: Identifiable, Codable, Equatable {
    let title: String
    let streamURL: String
    let localFilePath: String?
    let logoURL: String?
    let contentTypeRaw: String

    var id: String { streamURL }
    var contentType: IPTVContentType? { IPTVContentType(rawValue: contentTypeRaw) }

    init(title: String, streamURL: String, localFilePath: String?, logoURL: String?, contentTypeRaw: String) {
        self.title = title
        self.streamURL = streamURL
        self.localFilePath = localFilePath
        self.logoURL = logoURL
        self.contentTypeRaw = contentTypeRaw
    }

    init(channel: ChannelEntity, fallbackType: IPTVContentType) {
        self.init(
            title: channel.name,
            streamURL: channel.streamURL,
            localFilePath: channel.localFilePath,
            logoURL: channel.logoURL,
            contentTypeRaw: channel.contentType.isEmpty ? fallbackType.rawValue : channel.contentType
        )
    }
}

/// Persists a small per-profile "recently watched" list in UserDefaults.
/// Storing JSON under a per-profile key lets an `@AppStorage` binding in the
/// browser observe updates written from the player.
enum RecentChannelsStore {
    static let maxCount = 6

    static func key(for profileID: UUID) -> String {
        "recent_channels_\(profileID.uuidString)"
    }

    static func decode(_ json: String) -> [PlayableChannel] {
        guard let data = json.data(using: .utf8),
              let items = try? JSONDecoder().decode([PlayableChannel].self, from: data) else {
            return []
        }
        return items
    }

    static func load(profileID: UUID) -> [PlayableChannel] {
        decode(UserDefaults.standard.string(forKey: key(for: profileID)) ?? "")
    }

    static func record(_ channel: PlayableChannel, profileID: UUID) {
        var items = load(profileID: profileID)
        items.removeAll { $0.streamURL == channel.streamURL }
        items.insert(channel, at: 0)
        if items.count > maxCount {
            items = Array(items.prefix(maxCount))
        }
        if let data = try? JSONEncoder().encode(items),
           let json = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(json, forKey: key(for: profileID))
        }
    }
}

private struct PlayerView: View {
    private static let logger = Logger(subsystem: "ThreeAM.Apps.IPTV-Client", category: "Playback")

    let title: String
    let streamURL: String
    let localFilePath: String?
    let profileID: UUID?
    let contentType: IPTVContentType?
    let playlist: [PlayableChannel]

    private struct SubtitleOption: Identifiable {
        let id: String
        let title: String
        let option: AVMediaSelectionOption?
    }

    private struct ScreenSlot: Identifiable {
        let id = UUID()
        let title: String
        let streamURL: String
        let localFilePath: String?
    }

    private enum PlaybackStreamMode: String {
        case original
        case hls
    }

    private struct PlaybackDiagnostics {
        let lines: [String]
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext

    @AppStorage("show_playback_diagnostics") private var showPlaybackDiagnostics = false

    @State private var slots: [ScreenSlot] = []
    @State private var players: [UUID: AVPlayer] = [:]
    @State private var streamModes: [UUID: PlaybackStreamMode] = [:]
    @State private var hlsFallbackAttempts: Set<UUID> = []
    @State private var candidateChannels: [ChannelEntity] = []
    @State private var showAddChannelsSheet = false
    @State private var isLoadingCandidates = false
    @State private var subtitleGroup: AVMediaSelectionGroup?
    @State private var errorMessage: String?
    @State private var diagnosticsBySlotID: [UUID: PlaybackDiagnostics] = [:]
    @State private var diagnosticsTask: Task<Void, Never>?
    @State private var hlsFallbackTasks: [UUID: Task<Void, Never>] = [:]
    @State private var subtitleTask: Task<Void, Never>?
    @State private var isClosing = false
    @State private var currentIndex: Int?
    @State private var displayTitle: String
    @State private var isPrimaryFavorite = false
    @State private var recents: [PlayableChannel] = []
    @State private var showRecents = false
    @State private var lastPlaybackAction = ""
    @State private var isPlaybackMuted = false
    @State private var lastAudibleVolume: Float = 1
    #if os(tvOS) || targetEnvironment(macCatalyst)
    @State private var controlsVisible = true
    @State private var controlsHideTask: Task<Void, Never>?
    #endif

    private let maxScreens = 4

    init(
        title: String,
        streamURL: String,
        localFilePath: String?,
        profileID: UUID? = nil,
        contentType: IPTVContentType? = nil,
        playlist: [PlayableChannel] = []
    ) {
        self.title = title
        self.streamURL = streamURL
        self.localFilePath = localFilePath
        self.profileID = profileID
        self.contentType = contentType
        self.playlist = playlist
        self._displayTitle = State(initialValue: title)
    }

    /// Next/previous only make sense on a single stream, and require a playlist.
    private var canNavigatePlaylist: Bool {
        !playlist.isEmpty && slots.count <= 1 && !isClosing
    }

    private var canGoPrevious: Bool {
        canNavigatePlaylist && (currentIndex == nil || (currentIndex ?? 0) > 0)
    }

    private var canGoNext: Bool {
        canNavigatePlaylist && (currentIndex == nil || (currentIndex ?? 0) < playlist.count - 1)
    }

    #if os(tvOS) || targetEnvironment(macCatalyst)
    private func showControls() {
        controlsHideTask?.cancel()
        withAnimation {
            controlsVisible = true
        }
    }

    private func scheduleControlsHide(after seconds: UInt64) {
        controlsHideTask?.cancel()
        controlsHideTask = Task {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation {
                    controlsVisible = false
                }
            }
        }
    }

    private func revealControlsTemporarily() {
        showControls()
        scheduleControlsHide(after: 4)
    }
    #endif

    #if targetEnvironment(macCatalyst)
    private var topChromeHoverZone: some View {
        Rectangle()
            .fill(Color.black.opacity(0.001))
            .frame(maxWidth: .infinity)
            .frame(height: controlsVisible ? 96 : 36)
            .contentShape(Rectangle())
            .onHover { isHovering in
                if isHovering {
                    showControls()
                } else {
                    scheduleControlsHide(after: 2)
                }
            }
            .allowsHitTesting(true)
    }
    #endif

    var body: some View {
        Group {
            if isClosing {
                Color.black
                    .ignoresSafeArea()
            } else if slots.count > 1 {
                multiScreenGrid
            } else {
                singleScreenPlayer
            }
        }
        #if os(tvOS) || targetEnvironment(macCatalyst)
        .ignoresSafeArea()
        .onAppear {
            revealControlsTemporarily()
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                revealControlsTemporarily()
            }
        )
        #if targetEnvironment(macCatalyst)
        .overlay(alignment: .top) {
            topChromeHoverZone
        }
        #endif
        #endif
        .navigationTitle(displayTitle)
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    closePlayer()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
            }

            if !playlist.isEmpty {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button {
                        goToPreviousChannel()
                    } label: {
                        Image(systemName: "backward.end.fill")
                    }
                    .disabled(!canGoPrevious)

                    Button {
                        goToNextChannel()
                    } label: {
                        Image(systemName: "forward.end.fill")
                    }
                    .disabled(!canGoNext)
                }
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    togglePlaybackMute()
                } label: {
                    Image(systemName: isEffectivelyMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .disabled(isClosing || primaryPlayer == nil)
                .accessibilityLabel(isEffectivelyMuted ? "Unmute" : "Mute")

                if slots.count <= 1 {
                    Button {
                        togglePrimaryFavorite()
                    } label: {
                        Image(systemName: isPrimaryFavorite ? "star.fill" : "star")
                    }
                    .disabled(isClosing)
                }

                if !recents.isEmpty && slots.count <= 1 {
                    Button {
                        showRecents.toggle()
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .disabled(isClosing)
                    #if os(tvOS)
                    .sheet(isPresented: $showRecents) {
                        recentsPopover
                    }
                    #else
                    .popover(isPresented: $showRecents) {
                        recentsPopover
                    }
                    #endif
                }

                Button("Add Channels") {
                    openAddChannels()
                }
                .disabled(isClosing || !canOpenAddChannels)

                Button {
                    replayLast15Seconds()
                } label: {
                    Image(systemName: "gobackward.15")
                }
                .disabled(isClosing)

                Button("Replay") {
                    primaryPlayer?.seek(to: .zero)
                    primaryPlayer?.play()
                }
                .disabled(isClosing)

                if !isClosing, canSwitchPrimaryStreamMode {
                    Button(activePrimaryStreamMode == .hls ? "Original" : "HLS") {
                        switchPrimaryStreamMode()
                    }
                }

                Menu {
                    Toggle("Show diagnostics overlay", isOn: $showPlaybackDiagnostics)
                } label: {
                    Label("Diagnostics", systemImage: "waveform.path.ecg")
                }

                let subtitleOptions = subtitleOptions(for: primaryPlayer)
                if !subtitleOptions.isEmpty {
                    Menu {
                        let selectedID = selectedSubtitleOptionID(for: primaryPlayer)
                        ForEach(subtitleOptions) { option in
                            Button {
                                selectSubtitle(option.id, on: primaryPlayer)
                            } label: {
                                if selectedID == option.id {
                                    Label(option.title, systemImage: "checkmark")
                                } else {
                                    Text(option.title)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "captions.bubble")
                    }
                }

                AirPlayRoutePicker()
                    .frame(width: 24, height: 24)
            }
        }
        #if os(tvOS)
        .toolbar(controlsVisible ? .visible : .hidden, for: .automatic)
        #elseif targetEnvironment(macCatalyst)
        .toolbar(controlsVisible ? .visible : .hidden, for: .navigationBar)
        .toolbarBackground(controlsVisible ? .visible : .hidden, for: .navigationBar)
        #endif
        .task {
            initializePrimaryScreenIfNeeded()
            refreshPrimaryFavoriteState()
            if showPlaybackDiagnostics {
                startDiagnosticsLoopIfNeeded()
            }
        }
        .onChange(of: showPlaybackDiagnostics) {
            if showPlaybackDiagnostics {
                startDiagnosticsLoopIfNeeded()
            } else {
                stopDiagnosticsLoop()
                diagnosticsBySlotID = [:]
            }
        }
        .onDisappear {
            prepareForDismissal()
        }
        .sheet(isPresented: $showAddChannelsSheet) {
            NavigationStack {
                addChannelsSheet
            }
        }
        .alert(
            "Playback Error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var primaryPlayer: AVPlayer? {
        guard let slot = slots.first else { return nil }
        return players[slot.id]
    }

    private var primarySlot: ScreenSlot? {
        slots.first
    }

    private var isEffectivelyMuted: Bool {
        guard let player = primaryPlayer else { return isPlaybackMuted }
        return isPlaybackMuted || player.isMuted || player.volume <= 0.01
    }

    /// Provides a reliable escape from AVPlayerViewController's volume slider
    /// getting stuck at zero. If the native control has already reduced the
    /// player to silence, the first press restores audio immediately.
    private func togglePlaybackMute() {
        setPlaybackMuted(!isEffectivelyMuted)
    }

    private func setPlaybackMuted(_ muted: Bool) {
        if muted,
           let audibleVolume = players.values
            .map(\.volume)
            .first(where: { $0 > 0.01 }) {
            lastAudibleVolume = audibleVolume
        }

        isPlaybackMuted = muted
        for player in players.values {
            player.isMuted = muted
            if !muted, player.volume <= 0.01 {
                player.volume = max(lastAudibleVolume, 0.25)
            }
        }
        lastPlaybackAction = muted ? "Muted playback" : "Unmuted playback"
    }

    private func adjustPlaybackVolume(by step: Float) {
        let currentVolume = primaryPlayer?.volume ?? lastAudibleVolume
        setPlaybackVolume(currentVolume + step)
    }

    private func setPlaybackVolume(_ volume: Float) {
        let clampedVolume = min(max(volume, 0), 1)
        if clampedVolume <= 0.01 {
            setPlaybackMuted(true)
            return
        }

        isPlaybackMuted = false
        lastAudibleVolume = clampedVolume
        for player in players.values {
            player.isMuted = false
            player.volume = clampedVolume
        }
        lastPlaybackAction = "Volume \(Int((clampedVolume * 100).rounded()))%"
    }

    private var activePrimaryStreamMode: PlaybackStreamMode {
        guard let primarySlot else { return .original }
        return streamModes[primarySlot.id] ?? preferredStreamMode(for: primarySlot)
    }

    private var canSwitchPrimaryStreamMode: Bool {
        guard let primarySlot else { return false }
        return hlsFallbackURL(from: primarySlot) != nil
    }

    private var canOpenAddChannels: Bool {
        profileID != nil && contentType != nil && slots.count < maxScreens
    }

    private var singleScreenPlayer: some View {
        ZStack(alignment: .topLeading) {
            if let player = primaryPlayer {
                #if os(tvOS)
                AVPlayerControllerView(
                    player: player,
                    isMuted: isEffectivelyMuted,
                    volume: isEffectivelyMuted ? 0 : player.volume,
                    onToggleMute: { togglePlaybackMute() },
                    onVolumeDown: { adjustPlaybackVolume(by: -0.1) },
                    onVolumeUp: { adjustPlaybackVolume(by: 0.1) },
                    isFavorite: isPrimaryFavorite,
                    onToggleFavorite: { togglePrimaryFavorite() },
                    canGoNext: canGoNext,
                    onNext: { goToNextChannel() },
                    canGoPrevious: canGoPrevious,
                    onPrevious: { goToPreviousChannel() }
                )
                #else
                AVPlayerControllerView(player: player)
                #endif
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "play.slash")
                        .font(.system(size: 30))
                    Text("Unable to start playback")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if showPlaybackDiagnostics, let primarySlot {
                playbackDiagnosticsOverlay(for: primarySlot)
            }
        }
    }

    private var multiScreenGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ],
                spacing: 10
            ) {
                ForEach(slots) { slot in
                    multiScreenTile(slot: slot)
                }
            }
            .padding(10)
        }
    }

    private func multiScreenTile(slot: ScreenSlot) -> some View {
        ZStack(alignment: .topLeading) {
            if let player = players[slot.id] {
                AVPlayerControllerView(player: player)
            } else {
                Color.black.opacity(0.7)
                ProgressView()
                    .tint(.white)
            }

            if showPlaybackDiagnostics {
                playbackDiagnosticsOverlay(for: slot)
            }

            if slots.count > 1 {
                Button {
                    removeScreen(slot)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, .black.opacity(0.8))
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            VStack {
                Spacer()
                HStack {
                    Text(slot.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                }
                .padding(8)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func playbackDiagnosticsOverlay(for slot: ScreenSlot) -> some View {
        let diagnostics = diagnosticsBySlotID[slot.id] ?? playbackDiagnostics(for: slot, player: players[slot.id])

        return VStack(alignment: .leading, spacing: 4) {
            Label("Diagnostics", systemImage: "waveform.path.ecg")
                .font(.caption.weight(.semibold))

            ForEach(diagnostics.lines, id: \.self) { line in
                Text(line)
                    .lineLimit(1)
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.white)
        .padding(10)
        .frame(maxWidth: 360, alignment: .leading)
        .background(.black.opacity(0.74), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(10)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var addChannelsSheet: some View {
        List {
            Section {
                Text("Active screens: \(slots.count)/\(maxScreens)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            addChannelsSheetContent
        }
        .navigationTitle("Add Channels")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") {
                    showAddChannelsSheet = false
                }
            }
        }
    }

    @ViewBuilder
    private var addChannelsSheetContent: some View {
        if isLoadingCandidates {
            Section {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
        } else if candidateChannels.isEmpty {
            Section {
                Text(slots.count >= maxScreens ? "Maximum of 4 screens reached." : "No additional channels available.")
                    .foregroundStyle(.secondary)
            }
        } else {
            Section("Available Channels") {
                ForEach(candidateChannels, id: \.objectID) { channel in
                    addChannelRow(channel)
                }
            }
        }
    }

    private func addChannelRow(_ channel: ChannelEntity) -> some View {
        Button {
            addChannel(channel)
        } label: {
            HStack(spacing: 10) {
                ChannelLogoView(urlString: channel.logoURL, size: 36, circular: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let category = channel.categoryName, !category.isEmpty {
                        Text(category)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "plus.circle")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .buttonStyle(.plain)
    }

    private func initializePrimaryScreenIfNeeded() {
        guard slots.isEmpty else { return }

        let primary = ScreenSlot(
            title: title,
            streamURL: streamURL,
            localFilePath: localFilePath
        )
        slots = [primary]
        lastPlaybackAction = "Starting \(title)"
        createPlayerIfNeeded(for: primary)
        refreshSubtitleGroup(for: players[primary.id]?.currentItem)

        // Locate the starting channel within the playlist so next/previous can
        // continue from here (nil if it was launched from outside the list).
        currentIndex = playlist.firstIndex { $0.streamURL == streamURL }

        let startingItem = currentIndex.map { playlist[$0] }
            ?? PlayableChannel(
                title: title,
                streamURL: streamURL,
                localFilePath: localFilePath,
                logoURL: nil,
                contentTypeRaw: contentType?.rawValue ?? ""
            )
        recordRecent(startingItem)
        reloadRecents()
    }

    // MARK: - Playlist navigation

    private func refreshPrimaryFavoriteState() {
        guard let streamURL = primarySlot?.streamURL, let profileID else {
            isPrimaryFavorite = false
            return
        }
        let channel = try? IPTVDataStore.channel(profileID: profileID, streamURL: streamURL, in: viewContext)
        isPrimaryFavorite = channel?.isFavorite ?? false
    }

    private func togglePrimaryFavorite() {
        guard let streamURL = primarySlot?.streamURL, let profileID else { return }
        do {
            guard let channel = try IPTVDataStore.channel(profileID: profileID, streamURL: streamURL, in: viewContext) else {
                return
            }
            try IPTVDataStore.setFavorite(!channel.isFavorite, for: channel, in: viewContext)
            isPrimaryFavorite = channel.isFavorite
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func goToNextChannel() {
        guard canGoNext else { return }
        let target = (currentIndex ?? -1) + 1
        playPlaylistChannel(at: min(target, playlist.count - 1))
    }

    private func goToPreviousChannel() {
        guard canGoPrevious else { return }
        if let index = currentIndex {
            playPlaylistChannel(at: max(index - 1, 0))
        } else {
            playPlaylistChannel(at: playlist.count - 1)
        }
    }

    private func playPlaylistChannel(at index: Int) {
        guard playlist.indices.contains(index) else { return }
        playChannel(playlist[index], playlistIndex: index)
    }

    /// Swaps the primary stream in place rather than pushing a new player.
    private func playChannel(_ item: PlayableChannel, playlistIndex: Int?) {
        guard slots.count <= 1, let previous = slots.first else { return }

        let newSlot = ScreenSlot(
            title: item.title,
            streamURL: item.streamURL,
            localFilePath: item.localFilePath
        )

        let mode = preferredStreamMode(for: newSlot)
        guard let mediaURL = resolvedMediaURL(for: newSlot, mode: mode) else {
            let message = "Invalid media URL for \(item.title)"
            PlayerView.logger.error("\(message, privacy: .public)")
            errorMessage = message
            return
        }

        PlayerView.logger.notice(
            "Switching channel from '\(previous.title, privacy: .public)' to '\(item.title, privacy: .public)' at index \(playlistIndex ?? -1, privacy: .public). URL: \(mediaURL.absoluteString, privacy: .public)"
        )
        lastPlaybackAction = "Switching to \(item.title)"

        hlsFallbackTasks[previous.id]?.cancel()
        hlsFallbackTasks[previous.id] = nil
        streamModes[previous.id] = nil
        diagnosticsBySlotID[previous.id] = nil
        hlsFallbackAttempts.remove(previous.id)

        currentIndex = playlistIndex
        displayTitle = item.title

        if let player = players.removeValue(forKey: previous.id) {
            player.pause()
            player.cancelPendingPrerolls()
            player.currentItem?.cancelPendingSeeks()
            player.currentItem?.asset.cancelLoading()

            let playerItem = AVPlayerItem(url: mediaURL)
            streamModes[newSlot.id] = mode
            players[newSlot.id] = player
            slots = [newSlot]
            player.replaceCurrentItem(with: playerItem)
            player.play()
            refreshSubtitleGroup(for: playerItem)

            if showPlaybackDiagnostics {
                refreshPlaybackDiagnostics()
            }
            scheduleHLSFallbackIfNeeded(for: newSlot)
        } else {
            PlayerView.logger.warning("Primary player missing while switching channels; creating a replacement player.")
            slots = [newSlot]
            createPlayerIfNeeded(for: newSlot)
            refreshSubtitleGroup(for: players[newSlot.id]?.currentItem)
        }

        refreshPrimaryFavoriteState()
        recordRecent(item)
        reloadRecents()
    }

    private func playFromRecents(_ item: PlayableChannel) {
        showRecents = false
        if let index = playlist.firstIndex(where: { $0.streamURL == item.streamURL }) {
            playPlaylistChannel(at: index)
        } else {
            playChannel(item, playlistIndex: nil)
        }
    }

    private func recordRecent(_ item: PlayableChannel) {
        guard let profileID else { return }
        RecentChannelsStore.record(item, profileID: profileID)
    }

    private func reloadRecents() {
        guard let profileID else {
            recents = []
            return
        }
        // Exclude the currently-playing channel from the jump list.
        recents = RecentChannelsStore.load(profileID: profileID)
            .filter { $0.streamURL != (slots.first?.streamURL ?? streamURL) }
    }

    private var recentsPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recently Watched")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)

            ForEach(recents) { item in
                Button {
                    playFromRecents(item)
                } label: {
                    HStack(spacing: 10) {
                        ChannelLogoThumbnail(imageURL: item.logoURL)
                        Text(item.title)
                            .font(.subheadline)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 300)
        .padding(.bottom, 10)
    }

    private func openAddChannels() {
        guard canOpenAddChannels else { return }
        loadCandidateChannels()
        showAddChannelsSheet = true
    }

    private func loadCandidateChannels() {
        guard let profileID, let contentType else {
            candidateChannels = []
            return
        }

        isLoadingCandidates = true
        do {
            let fetched = try IPTVDataStore.fetchChannels(
                profileID: profileID,
                contentType: contentType,
                in: viewContext
            )
            let activeURLs = Set(slots.map(\.streamURL))
            candidateChannels = fetched.filter {
                !activeURLs.contains($0.streamURL) && !$0.streamURL.hasPrefix("series://")
            }
        } catch {
            candidateChannels = []
            errorMessage = error.localizedDescription
        }
        isLoadingCandidates = false
    }

    private func addChannel(_ channel: ChannelEntity) {
        guard slots.count < maxScreens else {
            return
        }

        let slot = ScreenSlot(
            title: channel.name,
            streamURL: channel.streamURL,
            localFilePath: channel.localFilePath
        )
        slots.append(slot)
        createPlayerIfNeeded(for: slot)
        loadCandidateChannels()

        if slots.count >= maxScreens {
            showAddChannelsSheet = false
        }
    }

    private func removeScreen(_ slot: ScreenSlot) {
        guard slots.count > 1 else { return }
        let wasPrimary = slots.first?.id == slot.id
        if let player = players[slot.id] {
            DeferredPlayerTeardown.shared.enqueue([player])
        }
        players[slot.id] = nil
        streamModes[slot.id] = nil
        diagnosticsBySlotID[slot.id] = nil
        hlsFallbackAttempts.remove(slot.id)
        hlsFallbackTasks[slot.id]?.cancel()
        hlsFallbackTasks[slot.id] = nil
        slots.removeAll { $0.id == slot.id }
        loadCandidateChannels()

        if wasPrimary, let newPrimary = slots.first {
            refreshSubtitleGroup(for: players[newPrimary.id]?.currentItem)
        }
    }

    private func closePlayer() {
        prepareForDismissal()
        dismiss()
    }

    private func prepareForDismissal() {
        guard !isClosing else { return }

        isClosing = true
        stopDiagnosticsLoop()
        #if os(tvOS) || targetEnvironment(macCatalyst)
        controlsHideTask?.cancel()
        controlsHideTask = nil
        #endif
        subtitleTask?.cancel()
        subtitleTask = nil
        subtitleGroup = nil

        for task in hlsFallbackTasks.values {
            task.cancel()
        }
        hlsFallbackTasks = [:]

        let playersForTeardown = Array(players.values)
        players = [:]
        slots = []
        streamModes = [:]
        diagnosticsBySlotID = [:]
        hlsFallbackAttempts = []

        DeferredPlayerTeardown.shared.enqueue(playersForTeardown)
    }

    private func replayLast15Seconds() {
        guard let player = primaryPlayer else { return }
        let currentTime = player.currentTime()
        let currentSeconds = CMTimeGetSeconds(currentTime)
        guard currentSeconds.isFinite else { return }

        let target = max(currentSeconds - 15, 0)
        let seekTime = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: seekTime)
    }

    private func subtitleOptions(for player: AVPlayer?) -> [SubtitleOption] {
        guard let player,
              player.currentItem != nil,
              let selectionGroup = subtitleGroup else {
            return []
        }

        var options: [SubtitleOption] = [
            SubtitleOption(id: "__off__", title: "Subtitles Off", option: nil)
        ]

        for option in selectionGroup.options {
            let title = option.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            options.append(
                SubtitleOption(
                    id: subtitleOptionID(for: option),
                    title: title.isEmpty ? "Subtitle" : title,
                    option: option
                )
            )
        }

        return options
    }

    private func selectedSubtitleOptionID(for player: AVPlayer?) -> String {
        guard let player,
              let currentItem = player.currentItem,
              let selectionGroup = subtitleGroup,
              let selectedOption = currentItem.currentMediaSelection.selectedMediaOption(in: selectionGroup) else {
            return "__off__"
        }
        return subtitleOptionID(for: selectedOption)
    }

    private func selectSubtitle(_ optionID: String, on player: AVPlayer?) {
        guard let player,
              let currentItem = player.currentItem,
              let selectionGroup = subtitleGroup else {
            return
        }

        guard optionID != "__off__" else {
            currentItem.select(nil, in: selectionGroup)
            return
        }

        if let option = selectionGroup.options.first(where: { subtitleOptionID(for: $0) == optionID }) {
            currentItem.select(option, in: selectionGroup)
        }
    }

    private func subtitleOptionID(for option: AVMediaSelectionOption) -> String {
        let language = option.extendedLanguageTag ?? option.locale?.identifier ?? option.displayName
        return "\(language)-\(option.displayName)"
    }

    private func createPlayerIfNeeded(for slot: ScreenSlot) {
        guard players[slot.id] == nil else { return }

        let mode = preferredStreamMode(for: slot)
        streamModes[slot.id] = mode

        guard let mediaURL = resolvedMediaURL(for: slot, mode: mode) else {
            errorMessage = "Invalid media URL for \(slot.title)"
            PlayerView.logger.error("Invalid media URL while creating player for '\(slot.title, privacy: .public)'")
            return
        }

        AudioSessionConfigurator.configureIfNeeded()

        PlayerView.logger.notice(
            "Creating player for '\(slot.title, privacy: .public)' using \(mediaURL.absoluteString, privacy: .public)"
        )
        let avPlayer = AVPlayer(url: mediaURL)
        avPlayer.allowsExternalPlayback = true
        avPlayer.automaticallyWaitsToMinimizeStalling = true
        avPlayer.isMuted = isPlaybackMuted
        if !isPlaybackMuted, avPlayer.volume <= 0.01 {
            avPlayer.volume = max(lastAudibleVolume, 0.25)
        }
        avPlayer.play()
        players[slot.id] = avPlayer
        if showPlaybackDiagnostics {
            refreshPlaybackDiagnostics()
            startDiagnosticsLoopIfNeeded()
        }
        scheduleHLSFallbackIfNeeded(for: slot)
    }

    private func startDiagnosticsLoopIfNeeded() {
        guard diagnosticsTask == nil else { return }

        diagnosticsTask = Task { @MainActor in
            while !Task.isCancelled {
                refreshPlaybackDiagnostics()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func stopDiagnosticsLoop() {
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
    }

    private func refreshPlaybackDiagnostics() {
        var nextDiagnostics: [UUID: PlaybackDiagnostics] = [:]
        for slot in slots {
            nextDiagnostics[slot.id] = playbackDiagnostics(for: slot, player: players[slot.id])
        }
        diagnosticsBySlotID = nextDiagnostics
    }

    private func playbackDiagnostics(for slot: ScreenSlot, player: AVPlayer?) -> PlaybackDiagnostics {
        let mode = streamModes[slot.id] ?? preferredStreamMode(for: slot)
        var lines = [
            "Mode: \(mode == .hls ? "HLS" : "Original")",
            "Source: \(slot.localFilePath == nil ? "Network stream" : "Local file")"
        ]

        guard let player else {
            lines.append("Player: not created")
            return PlaybackDiagnostics(lines: lines)
        }

        if !lastPlaybackAction.isEmpty {
            lines.append("Action: \(shortDiagnosticText(lastPlaybackAction, limit: 44))")
        }
        lines.append("Player: \(playerTimeControlText(player))")

        if let currentItem = player.currentItem {
            lines.append("Item: \(playerItemStatusText(currentItem.status))")
            lines.append("Buffer: \(playerBufferText(currentItem))")

            if let event = currentItem.accessLog()?.events.last {
                let throughput = effectiveBitrate(from: event)
                if throughput > 0 {
                    lines.append("Stream throughput: \(bitrateText(throughput))")
                } else {
                    lines.append("Stream throughput: collecting")
                }

                if event.indicatedBitrate > 0 {
                    lines.append("Declared bitrate: \(bitrateText(event.indicatedBitrate))")
                }

                lines.append("Stalls: \(event.numberOfStalls)")

                if event.numberOfBytesTransferred > 0 {
                    lines.append("Downloaded: \(byteCountText(Int64(event.numberOfBytesTransferred)))")
                }

                if event.segmentsDownloadedDuration > 0 {
                    lines.append("Media fetched: \(durationText(event.segmentsDownloadedDuration))")
                }

                if let serverAddress = event.serverAddress, !serverAddress.isEmpty {
                    lines.append("Server: \(shortDiagnosticText(serverAddress, limit: 34))")
                }
            } else if slot.localFilePath == nil {
                lines.append("Stream throughput: collecting")
            }

            if let itemError = currentItem.error {
                lines.append("Item error: \(shortDiagnosticText(itemError.localizedDescription, limit: 44))")
            }
        } else {
            lines.append("Item: none")
        }

        if let playerError = player.error {
            lines.append("Player error: \(shortDiagnosticText(playerError.localizedDescription, limit: 44))")
        }

        return PlaybackDiagnostics(lines: lines)
    }

    private func playerTimeControlText(_ player: AVPlayer) -> String {
        switch player.timeControlStatus {
        case .paused:
            return "paused"
        case .playing:
            return "playing"
        case .waitingToPlayAtSpecifiedRate:
            if let reason = waitingReasonText(player.reasonForWaitingToPlay) {
                return "waiting (\(reason))"
            }
            return "waiting"
        @unknown default:
            return "unknown"
        }
    }

    private func waitingReasonText(_ reason: AVPlayer.WaitingReason?) -> String? {
        guard let rawValue = reason?.rawValue else { return nil }

        if rawValue.contains("MinimizeStalls") {
            return "buffering"
        } else if rawValue.contains("EvaluatingBufferingRate") {
            return "checking buffer"
        } else if rawValue.contains("NoItemToPlay") {
            return "no item"
        }

        return shortDiagnosticText(rawValue, limit: 28)
    }

    private func playerItemStatusText(_ status: AVPlayerItem.Status) -> String {
        switch status {
        case .unknown:
            return "unknown"
        case .readyToPlay:
            return "ready"
        case .failed:
            return "failed"
        @unknown default:
            return "unknown"
        }
    }

    private func playerBufferText(_ item: AVPlayerItem) -> String {
        let empty = item.isPlaybackBufferEmpty ? "empty" : "ok"
        let keepUp = item.isPlaybackLikelyToKeepUp ? "yes" : "no"
        let full = item.isPlaybackBufferFull ? "yes" : "no"
        return "\(empty), keep-up \(keepUp), full \(full)"
    }

    private func effectiveBitrate(from event: AVPlayerItemAccessLogEvent) -> Double {
        if event.observedBitrate > 0 {
            return event.observedBitrate
        }

        if event.transferDuration > 0, event.numberOfBytesTransferred > 0 {
            return Double(event.numberOfBytesTransferred) * 8 / event.transferDuration
        }

        return 0
    }

    private func bitrateText(_ bitsPerSecond: Double) -> String {
        let mbps = bitsPerSecond / 1_000_000
        if mbps >= 1 {
            return String(format: "%.1f Mbps", mbps)
        }
        return String(format: "%.0f Kbps", bitsPerSecond / 1_000)
    }

    private func byteCountText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func durationText(_ seconds: Double) -> String {
        if seconds >= 60 {
            return String(format: "%.1f min", seconds / 60)
        }
        return String(format: "%.0f sec", seconds)
    }

    private func shortDiagnosticText(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let endIndex = text.index(text.startIndex, offsetBy: max(limit - 1, 1))
        return String(text[..<endIndex]) + "..."
    }

    private func resolvedMediaURL(for slot: ScreenSlot, mode: PlaybackStreamMode) -> URL? {
        if let localFilePath = slot.localFilePath,
           FileManager.default.fileExists(atPath: localFilePath) {
            return URL(fileURLWithPath: localFilePath)
        }

        if mode == .hls, let fallbackURL = hlsFallbackURL(from: slot) {
            return fallbackURL
        }

        return URL(string: slot.streamURL)
    }

    private func preferredStreamMode(for slot: ScreenSlot) -> PlaybackStreamMode {
        guard hlsFallbackURL(from: slot) != nil,
              isUltraHDLiveChannel(slot.title) else {
            return .original
        }
        return .hls
    }

    private func isUltraHDLiveChannel(_ title: String) -> Bool {
        let uppercased = title.uppercased()
        return uppercased.contains("4K")
            || uppercased.contains("UHD")
            || uppercased.contains("ULTRA HD")
    }

    private func scheduleHLSFallbackIfNeeded(for slot: ScreenSlot) {
        guard hlsFallbackURL(from: slot) != nil,
              streamModes[slot.id] != .hls else { return }

        hlsFallbackTasks[slot.id]?.cancel()
        hlsFallbackTasks[slot.id] = Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            retryWithHLSFallbackIfNeeded(for: slot)
        }
    }

    private func retryWithHLSFallbackIfNeeded(for slot: ScreenSlot) {
        hlsFallbackTasks[slot.id] = nil
        guard !hlsFallbackAttempts.contains(slot.id),
              let player = players[slot.id],
              streamModes[slot.id] != .hls,
              let fallbackURL = hlsFallbackURL(from: slot) else {
            return
        }

        hlsFallbackAttempts.insert(slot.id)
        streamModes[slot.id] = .hls
        lastPlaybackAction = "HLS fallback for \(slot.title)"
        PlayerView.logger.notice("Trying HLS fallback for '\(slot.title, privacy: .public)'")
        let item = AVPlayerItem(url: fallbackURL)
        player.replaceCurrentItem(with: item)
        player.play()
        refreshSubtitleGroup(for: item)
    }

    private func switchPrimaryStreamMode() {
        guard let primarySlot,
              let player = primaryPlayer else {
            return
        }

        let currentMode = streamModes[primarySlot.id] ?? preferredStreamMode(for: primarySlot)
        let newMode: PlaybackStreamMode = currentMode == .hls ? .original : .hls

        guard let mediaURL = resolvedMediaURL(for: primarySlot, mode: newMode) else {
            errorMessage = "Invalid media URL for \(primarySlot.title)"
            return
        }

        streamModes[primarySlot.id] = newMode
        hlsFallbackAttempts.insert(primarySlot.id)
        lastPlaybackAction = "Switching mode for \(primarySlot.title)"
        PlayerView.logger.notice(
            "Switching stream mode for '\(primarySlot.title, privacy: .public)' to \(newMode.rawValue, privacy: .public)"
        )
        let item = AVPlayerItem(url: mediaURL)
        player.replaceCurrentItem(with: item)
        player.play()
        refreshSubtitleGroup(for: item)
    }

    private func hlsFallbackURL(from slot: ScreenSlot) -> URL? {
        guard slot.localFilePath == nil,
              contentType == .live,
              var url = URL(string: slot.streamURL),
              url.pathExtension.lowercased() != "m3u8" else {
            return nil
        }

        url.deletePathExtension()
        url.appendPathExtension("m3u8")
        return url
    }

    private func refreshSubtitleGroup(for item: AVPlayerItem?) {
        subtitleTask?.cancel()

        guard let item else {
            subtitleGroup = nil
            return
        }

        subtitleTask = Task {
            do {
                let group = try await item.asset.loadMediaSelectionGroup(for: .legible)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    subtitleGroup = group
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    subtitleGroup = nil
                }
            }
        }
    }
}

/// Configures the shared AVAudioSession exactly once for the app's lifetime.
///
/// `AVAudioSession.setActive(true)` is a synchronous call that can block the
/// main thread for seconds while the system negotiates the audio route — doing
/// it on every channel open froze the UI each time playback started. The
/// category/active state only needs to be established once, so subsequent
/// channels reuse the already-active session.
private enum AudioSessionConfigurator {
    private static var isConfigured = false

    @MainActor
    static func configureIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true

        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .moviePlayback,
                options: [.allowAirPlay]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Playback can still continue if audio session setup fails; allow a
            // future attempt to retry.
            isConfigured = false
        }
    }
}

@MainActor
private final class DeferredPlayerTeardown {
    static let shared = DeferredPlayerTeardown()

    private var retainedPlayers: [ObjectIdentifier: AVPlayer] = [:]

    func enqueue(_ players: [AVPlayer]) {
        guard !players.isEmpty else { return }

        let identifiers = players.map { ObjectIdentifier($0) }
        for player in players {
            retainedPlayers[ObjectIdentifier(player)] = player
            player.pause()
            player.cancelPendingPrerolls()
            player.currentItem?.cancelPendingSeeks()
            player.currentItem?.asset.cancelLoading()
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_250_000_000)
            for identifier in identifiers {
                guard let player = retainedPlayers.removeValue(forKey: identifier) else { continue }
                player.replaceCurrentItem(with: nil)
            }
        }
    }
}

private struct AVPlayerControllerView: UIViewControllerRepresentable {
    let player: AVPlayer

    #if os(tvOS)
    // On tvOS the AVPlayerViewController owns the focus environment, so the
    // SwiftUI toolbar over it is unreachable. These actions are surfaced in the
    // player's own transport bar instead (revealed by swiping down on the
    // remote), which is the only focusable place for them.
    var isMuted = false
    var volume: Float = 1
    var onToggleMute: (() -> Void)?
    var onVolumeDown: (() -> Void)?
    var onVolumeUp: (() -> Void)?
    var isFavorite = false
    var onToggleFavorite: (() -> Void)?
    var canGoNext = false
    var onNext: (() -> Void)?
    var canGoPrevious = false
    var onPrevious: (() -> Void)?
    #endif

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = true
        #if !os(tvOS)
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        controller.updatesNowPlayingInfoCenter = true
        #else
        controller.transportBarCustomMenuItems = makeTransportBarItems()
        #endif
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        uiViewController.player = player
        #if os(tvOS)
        uiViewController.transportBarCustomMenuItems = makeTransportBarItems()
        #endif
    }

    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: ()) {
        uiViewController.player = nil
    }

    #if os(tvOS)
    private func makeTransportBarItems() -> [UIMenuElement] {
        var channelActions: [UIMenuElement] = []

        if let onToggleFavorite {
            channelActions.append(
                UIAction(
                    title: isFavorite ? "Remove Favorite" : "Add to Favorites",
                    image: UIImage(systemName: isFavorite ? "star.slash.fill" : "star")
                ) { _ in onToggleFavorite() }
            )
        }
        if canGoPrevious, let onPrevious {
            channelActions.append(
                UIAction(title: "Previous Channel", image: UIImage(systemName: "backward.end.fill")) { _ in onPrevious() }
            )
        }
        if canGoNext, let onNext {
            channelActions.append(
                UIAction(title: "Next Channel", image: UIImage(systemName: "forward.end.fill")) { _ in onNext() }
            )
        }

        var items: [UIMenuElement] = []
        if !channelActions.isEmpty {
            items.append(
                UIMenu(
                    title: "Channel",
                    image: UIImage(systemName: "ellipsis.circle"),
                    children: channelActions
                )
            )
        }

        // tvOS may collapse earlier custom items when the transport bar is
        // crowded. Keep the complete volume menu last so its speaker button
        // remains directly visible beside the Live timeline.
        if onVolumeDown != nil || onToggleMute != nil || onVolumeUp != nil {
            var volumeActions: [UIMenuElement] = []
            if let onVolumeDown {
                volumeActions.append(
                    UIAction(title: "Volume Down", image: UIImage(systemName: "speaker.minus.fill")) { _ in onVolumeDown() }
                )
            }
            if let onToggleMute {
                volumeActions.append(
                    UIAction(
                        title: isMuted ? "Unmute" : "Mute",
                        image: UIImage(systemName: isMuted ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    ) { _ in onToggleMute() }
                )
            }
            if let onVolumeUp {
                volumeActions.append(
                    UIAction(title: "Volume Up", image: UIImage(systemName: "speaker.plus.fill")) { _ in onVolumeUp() }
                )
            }

            let percentage = Int((min(max(volume, 0), 1) * 100).rounded())
            items.append(
                UIMenu(
                    title: "Volume \(percentage)%",
                    image: UIImage(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"),
                    children: volumeActions
                )
            )
        }
        return items
    }
    #endif
}

private struct AirPlayRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView(frame: .zero)
        view.prioritizesVideoDevices = true
        view.tintColor = UIColor.systemPink
        view.activeTintColor = UIColor.systemPink
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

private struct ChannelLogoView: View {
    let urlString: String?
    let size: CGFloat
    let circular: Bool

    @ViewBuilder
    private var imageContent: some View {
        if let urlString, let url = URL(string: urlString) {
            CachedAsyncImage(url: url, maxPixelSize: size * 2) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                placeholder
            }
        } else {
            placeholder
        }
    }

    var body: some View {
        if circular {
            imageContent
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.black.opacity(0.08), lineWidth: 1))
        } else {
            imageContent
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.08), lineWidth: 1))
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.gray.opacity(0.15)
            Image(systemName: "tv")
                .foregroundStyle(.secondary)
        }
    }
}

enum OfflineStorage {
    static func download(from remoteURL: URL, suggestedName: String) async throws -> String {
        let fileManager = FileManager.default
        let downloadsDirectory = try offlineDirectory()

        let (temporaryURL, response) = try await URLSession.shared.download(from: remoteURL)

        let responseExtension = (response.suggestedFilename as NSString?)?.pathExtension
        let ext = !remoteURL.pathExtension.isEmpty
            ? remoteURL.pathExtension
            : (responseExtension?.isEmpty == false ? responseExtension! : "mp4")

        let safeName = sanitizeFileName(suggestedName)
        let finalURL = downloadsDirectory
            .appendingPathComponent("\(safeName)-\(UUID().uuidString)")
            .appendingPathExtension(ext)

        if fileManager.fileExists(atPath: finalURL.path) {
            try fileManager.removeItem(at: finalURL)
        }

        try fileManager.moveItem(at: temporaryURL, to: finalURL)
        return finalURL.path
    }

    static func offlineDirectory() throws -> URL {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = root.appendingPathComponent("Offline", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private static func sanitizeFileName(_ input: String) -> String {
        let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|")
        let cleaned = input
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? "offline-item" : cleaned
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
