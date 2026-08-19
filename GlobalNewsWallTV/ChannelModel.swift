import Foundation

enum ChannelCategory: String, CaseIterable, Identifiable, Codable {
    case all
    case favorites
    case m3u
    case go2rtc

    var id: String { rawValue }
}

enum ChannelSourceFilter: String, CaseIterable, Identifiable, Codable {
    case all
    case iptv
    case go2rtc

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "全部"
        case .iptv: return "IPTV"
        case .go2rtc: return "go2rtc"
        }
    }
}

#if os(macOS)
private struct IPTVOrgAPIChannel: Decodable {
    let id: String
    let name: String
    let country: String
    let categories: [String]
    let is_nsfw: Bool
    let closed: String?
}

private struct IPTVOrgAPIStream: Decodable {
    let channel: String?
    let feed: String?
    let url: String
    let quality: String?
    let label: String?
    let user_agent: String?
    let referrer: String?

    var qualityScore: Int {
        Int(quality?.filter(\.isNumber) ?? "") ?? 0
    }
}

private struct IPTVOrgAPIFeed: Decodable {
    let channel: String
    let id: String
    let languages: [String]
}
#endif

enum WallMode: String, CaseIterable, Identifiable {
    case four = "4×4"
    case five = "5×5"
    case six = "6×6"
    case seven = "7×7"
    case fullscreen = "全螢幕"

    var id: String { rawValue }

    var gridDimension: Int {
        switch self {
        case .four, .fullscreen: return 4
        case .five: return 5
        case .six: return 6
        case .seven: return 7
        }
    }

    var pageSize: Int {
        switch self {
        case .fullscreen: return 12
        case .four, .five, .six, .seven: return 4 * gridDimension - 4
        }
    }
}

#if os(macOS)
struct Go2RTCScanStatus {
    enum Stage {
        case discovering
        case verifying
    }

    let stage: Stage
    let scannedHosts: Int
    let totalHosts: Int
    let foundServers: Int
    let verifiedStreams: Int
}
#endif

struct NewsChannel: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let url: URL
    let logoURL: URL?
    let country: String
    let category: ChannelCategory
}

@MainActor
final class ChannelStore: ObservableObject {
    @Published var channels: [NewsChannel] = []
    @Published var go2rtcChannels: [NewsChannel] = []
    @Published var unavailable: Set<String> = []
    @Published var deletedChannelIDs: Set<String>
    @Published var isLoading = true
    @Published var importedPlaylists: [ImportedPlaylistRecord]
    @Published var isImportingM3U = false
    @Published var isSyncingRemoteM3U = false
    @Published var remoteSyncSettings: RemotePlaylistSyncSettings
    @Published var category: ChannelCategory
    @Published var sourceFilter: ChannelSourceFilter
    @Published var selectedCountry = "ALL"
    @Published var mode: WallMode
    @Published var page = 0
    @Published var featuredID: String?
    @Published var favorites: Set<String>
    @Published var favoriteOrder: [String]
    @Published var isCloudLibrarySyncEnabled: Bool
    @Published var isSyncingCloudLibrary = false
    @Published var cloudLibraryLastSyncedAt: Date?
    @Published var cloudLibraryError: String?

    private let defaults = UserDefaults.standard
    private let cloudStore = NSUbiquitousKeyValueStore.default
    private var cloudObserver: NSObjectProtocol?
    private var cloudLibrarySyncTask: Task<Void, Never>?
    private var cloudLibraryModifiedAt: Date
    private var isApplyingCloudLibrarySnapshot = false
    private let cloudFavoritesKey = "favorites.v1"
    private let cloudLibraryEnabledKey = "cloudLibrarySyncEnabled.v1"
    private let cloudLibraryModifiedAtKey = "cloudLibraryModifiedAt.v1"
    private let cloudLibraryLastSyncedAtKey = "cloudLibraryLastSyncedAt.v1"
    private let cloudLibraryLastAttemptAtKey = "cloudLibraryLastAttemptAt.v1"
    private let m3uDefaultMigrationKey = "m3uDefaultCategoryMigrationV1"
    private let lastM3UFeatureIDKey = "lastM3UFeatureID"
    // Keep the legacy identifier so existing remote-sync settings and iCloud data migrate
    // without creating a duplicate playlist. It is not shown to users.
    private let remotePlaylistID = "business-remote-m3u"
    private let go2rtcChannelsKey = "go2rtc.channels.v1"
    private let sourceFilterKey = "sourceFilter.v1"
    #if os(macOS)
    @Published var catalogChannels: [IPTVOrgCatalogChannel] = []
    @Published var isLoadingCatalog = false
    @Published var catalogError: String?
    @Published var isAddingStarterChannels = false
    @Published var go2rtcScanStatus: Go2RTCScanStatus?
    @Published var isScanningGo2RTC = false
    @Published var go2rtcScanCandidates: [Go2RTCDiscovery.Candidate] = []
    private let discoveredPlaylistID = "iptv-org-discoveries"
    private let catalogMaxAge: TimeInterval = 60 * 60 * 24
    private static let starterPlaylistID = "starter-recommended-v1"
    private static let starterPlaylistName = "新手推薦頻道"
    private static let bundledStarterM3U = """
    #EXTM3U
    #PLAYLIST:IPTV Wall Starter Channels
    #EXTINF:-1 tvg-id="aljazeera" tvg-country="QA",Al Jazeera English
    https://live-hls-apps-aje-fa.getaj.net/AJE/index.m3u8
    #EXTINF:-1 tvg-id="arirang" tvg-country="KR",Arirang TV
    http://amdlive-ch01.ctnd.com.edgesuite.net/arirang_1ch/smil:arirang_1ch.smil/playlist.m3u8
    #EXTINF:-1 tvg-id="bbc" tvg-country="GB",BBC News North America
    https://gpuserver3.tier1streams.com/BBC_WORLD_NEWS/index.m3u8
    #EXTINF:-1 tvg-id="citynewstoronto" tvg-country="CA",CityNews Toronto
    https://citynewsregional.akamaized.net/hls/live/1024052/Regional_Live_7/master.m3u8
    #EXTINF:-1 tvg-id="cbs" tvg-country="US",CBS News 24/7
    https://jmp2.uk/plu-6350fdd266e9ea0007bedec5.m3u8
    #EXTINF:-1 tvg-id="dw" tvg-country="DE",DW English
    https://amg01644-amg01644c1-amgplt0343.playout.now3.amagi.tv/ts-eu-w1-n2/playlist/amg01644-amg01644c1-amgplt0343/playlist.m3u8
    #EXTINF:-1 tvg-id="euronews" tvg-country="FR",Euronews English
    https://jmp2.uk/plu-61de96114757070008d33cae.m3u8
    #EXTINF:-1 tvg-id="france24" tvg-country="FR",France 24 English
    https://live.france24.com/hls/live/2037218-b/F24_EN_HI_HLS/master_5000.m3u8
    #EXTINF:-1 tvg-id="nbc" tvg-country="US",NBC News NOW
    https://d1si3n1st4nkgb.cloudfront.net/10502/88896001/hls/master.m3u8?ads.xumo_channelId=88896001
    #EXTINF:-1 tvg-id="nhk" tvg-country="JP",NHK World-Japan
    https://masterpl.hls.nhkworld.jp/hls/w/live/smarttv.m3u8
    #EXTINF:-1 tvg-id="reuters" tvg-country="US",Reuters
    https://amg00453-reuters-amg00453c1-rakuten-uk-2110.playouts.now.amagi.tv/playlist/amg00453-reuters-reuters-rakutenuk/playlist.m3u8
    #EXTINF:-1 tvg-id="trt" tvg-country="TR",TRT World
    https://dash2.antik.sk/live/test_trt_world_atktv/playlist.m3u8
    #EXTINF:-1 tvg-id="wion" tvg-country="IN",WION
    http://vg-zeefta.akamaized.net/ptnr-yupptv/title-wion/v1/master/611d79b11b77e2f571934fd80ca1413453772ac7/20c3c0d9-0256-43fe-bca6-70fdd490b957/main.m3u8
    #EXTINF:-1 tvg-id="bloomberg" tvg-country="US",Bloomberg TV Asia
    https://bloomberg.com/media-manifest/streams/asia.m3u8
    #EXTINF:-1 tvg-id="cnbctv18" tvg-country="IN",CNBC TV18
    https://n18syndication.akamaized.net/bpk-tv/CNBC_TV18_NW18_MOB/output01/index.m3u8
    #EXTINF:-1 tvg-id="abcnewsaustralia" tvg-country="AU",ABC News Australia
    https://abc-news-dmd-streams-1.akamaized.net/out/v1/701126012d044971b3fa89406a440133/index.m3u8
    """
    #endif

    init() {
        // New installs open on all playable M3U-backed channels. Old "m3u" category selections
        // are migrated into "all" so M3U becomes a source, not a top-level playlist.
        if defaults.bool(forKey: m3uDefaultMigrationKey) {
            let saved = ChannelCategory(rawValue: defaults.string(forKey: "category") ?? "") ?? .all
            category = saved == .m3u ? .all : saved
        } else {
            category = .all
            defaults.set(ChannelCategory.all.rawValue, forKey: "category")
            defaults.set(true, forKey: m3uDefaultMigrationKey)
        }
        sourceFilter = ChannelSourceFilter(rawValue: defaults.string(forKey: sourceFilterKey) ?? "") ?? .all
        mode = WallMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .five
        let localFavorites = defaults.stringArray(forKey: "favorites") ?? []
        let localDeletedChannelIDs = defaults.stringArray(forKey: "deletedChannelIDs") ?? []
        var localImportedPlaylists = M3UPlaylistLibrary.load()
        if let remoteIndex = localImportedPlaylists.firstIndex(where: { $0.id == "business-remote-m3u" }),
           localImportedPlaylists[remoteIndex].name == "Business Remote M3U" {
            localImportedPlaylists[remoteIndex].name = "Remote M3U Sync"
            try? M3UPlaylistLibrary.save(localImportedPlaylists)
        }
        let localM3UPriorityOrder = defaults.stringArray(forKey: "m3uPriorityOrder") ?? []
        let localRemoteSyncSettings = RemotePlaylistSyncLibrary.load()
        favorites = Set(localFavorites)
        favoriteOrder = defaults.stringArray(forKey: "favoriteOrder") ?? localFavorites
        deletedChannelIDs = Set(localDeletedChannelIDs)
        importedPlaylists = localImportedPlaylists
        remoteSyncSettings = localRemoteSyncSettings
        go2rtcChannels = Self.loadGo2RTCChannels(from: defaults, key: go2rtcChannelsKey)
        if defaults.object(forKey: "cloudLibrarySyncEnabled.v1") == nil {
            #if os(iOS)
            // Do not initialize a named CloudKit container during first launch. The user can
            // explicitly restore from iCloud, after App Store signing has been validated.
            isCloudLibrarySyncEnabled = false
            #else
            isCloudLibrarySyncEnabled = true
            #endif
        } else {
            isCloudLibrarySyncEnabled = defaults.bool(forKey: "cloudLibrarySyncEnabled.v1")
        }
        cloudLibraryLastSyncedAt = defaults.object(forKey: "cloudLibraryLastSyncedAt.v1") as? Date
        cloudLibraryModifiedAt = defaults.object(forKey: "cloudLibraryModifiedAt.v1") as? Date
            ?? (
                localFavorites.isEmpty &&
                localDeletedChannelIDs.isEmpty &&
                localImportedPlaylists.isEmpty &&
                localM3UPriorityOrder.isEmpty &&
                localRemoteSyncSettings == .disabled
                    ? .distantPast
                    : Date()
            )
        setupCloudFavoritesSync()
    }

    deinit {
        cloudLibrarySyncTask?.cancel()
        if let cloudObserver { NotificationCenter.default.removeObserver(cloudObserver) }
    }

    var filteredChannels: [NewsChannel] {
        visibleChannels(category: category, sourceFilter: sourceFilter)
    }

    func channelCount(category: ChannelCategory, sourceFilter: ChannelSourceFilter) -> Int {
        visibleChannels(category: category, sourceFilter: sourceFilter).count
    }

    private func visibleChannels(category: ChannelCategory, sourceFilter: ChannelSourceFilter) -> [NewsChannel] {
        let filtered = channels.filter { channel in
            guard !unavailable.contains(channel.id) else { return false }
            guard !deletedChannelIDs.contains(channel.id) else { return false }
            let categoryMatches = category == .favorites ? isFavorite(channel) : true
            let sourceMatches: Bool
            switch sourceFilter {
            case .all: sourceMatches = true
            case .iptv: sourceMatches = channel.category == .m3u
            case .go2rtc: sourceMatches = channel.category == .go2rtc
            }
            return categoryMatches && sourceMatches && (selectedCountry == "ALL" || channel.country == selectedCountry)
        }
        if category == .all {
            let order = Dictionary(uniqueKeysWithValues: m3uPriorityOrder.enumerated().map { ($0.element, $0.offset) })
            return filtered.enumerated()
                .sorted { lhs, rhs in
                    let leftPriority = order[lhs.element.id] ?? Int.max
                    let rightPriority = order[rhs.element.id] ?? Int.max
                    return leftPriority == rightPriority ? lhs.offset < rhs.offset : leftPriority < rightPriority
                }
                .map(\.element)
        }
        guard category == .favorites else { return filtered }
        let order = Dictionary(uniqueKeysWithValues: normalizedFavoriteOrder().enumerated().map { ($0.element, $0.offset) })
        return filtered.sorted {
            (order[favoriteIdentifier(for: $0)] ?? Int.max) < (order[favoriteIdentifier(for: $1)] ?? Int.max)
        }
    }

    var countries: [(String, Int)] {
        var counts: [String: Int] = [:]
        for channel in channels where !unavailable.contains(channel.id) && !deletedChannelIDs.contains(channel.id) {
            let categoryMatches = category == .favorites ? isFavorite(channel) : true
            if categoryMatches { counts[channel.country, default: 0] += 1 }
        }
        return counts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
    }

    #if os(macOS)
    var starterPlaylistChannelCount: Int {
        Self.bundledStarterChannels.count
    }
    #endif

    var pageCount: Int {
        max(1, Int(ceil(Double(filteredChannels.count) / Double(mode.pageSize))))
    }

    var pageChannels: [NewsChannel] {
        let safePage = page % pageCount
        let start = safePage * mode.pageSize
        guard start < filteredChannels.count else { return [] }
        let currentGroup = Array(filteredChannels[start..<min(start + mode.pageSize, filteredChannels.count)])
        guard safePage > 0, currentGroup.count < mode.pageSize else { return currentGroup }

        let missingCount = mode.pageSize - currentGroup.count
        let previousStart = max(0, start - mode.pageSize)
        let previousGroup = Array(filteredChannels[previousStart..<start])
        return currentGroup + Array(previousGroup.prefix(missingCount))
    }

    func displayIndex(of channel: NewsChannel) -> Int {
        (filteredChannels.firstIndex(where: { $0.id == channel.id }) ?? 0) + 1
    }

    var featured: NewsChannel? {
        if let savedID = defaults.string(forKey: lastM3UFeatureIDKey),
           let channel = filteredChannels.first(where: { $0.id == savedID }) {
            return channel
        }
        if let featuredID, let channel = filteredChannels.first(where: { $0.id == featuredID }) {
            return channel
        }
        return filteredChannels.first
    }

    func load() async {
        isLoading = true
        await syncCloudLibraryIfNeeded(force: true)
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--import-m3u-url=") }) {
            let source = String(argument.dropFirst("--import-m3u-url=".count))
            do {
                let count = try await importM3U(from: source)
                category = .all
                defaults.set(ChannelCategory.all.rawValue, forKey: "category")
                print("M3U_IMPORT_SUCCEEDED channels=\(count)")
            } catch {
                print("M3U_IMPORT_FAILED error=\(error.localizedDescription)")
            }
        }
        channels = combinedChannels()
        normalizePage()
        await syncRemotePlaylistIfNeeded(force: false)
        // Remote sync can also add a playlist. Publish the loaded state only after every
        // startup source has finished so first-use never races into the wall view.
        channels = combinedChannels()
        isLoading = false

    }

    func setCloudLibrarySyncEnabled(_ enabled: Bool) {
        isCloudLibrarySyncEnabled = enabled
        defaults.set(enabled, forKey: cloudLibraryEnabledKey)
        cloudLibraryError = nil
        cloudLibrarySyncTask?.cancel()
        guard enabled else { return }
        cloudLibrarySyncTask = Task { [weak self] in
            await self?.syncCloudLibraryIfNeeded(force: true)
        }
    }

    #if os(macOS)
    func addStarterChannels() throws {
        guard !isAddingStarterChannels else { return }
        isAddingStarterChannels = true
        defer { isAddingStarterChannels = false }

        if !importedPlaylists.contains(where: { $0.id == Self.starterPlaylistID }) {
            let playlist = ImportedPlaylistRecord(
                id: Self.starterPlaylistID,
                name: Self.starterPlaylistName,
                sourceURL: "iptvwall://starter-recommended-v1",
                content: Self.bundledStarterM3U,
                channelCount: Self.bundledStarterChannels.count,
                importedAt: Date()
            )
            importedPlaylists.insert(playlist, at: 0)
            try M3UPlaylistLibrary.save(importedPlaylists)
        }

        refreshImportedChannels()
        guard let firstChannel = Self.bundledStarterChannels.first else { return }
        prioritizeM3UChannel(id: firstChannel.id)
    }

    @discardableResult
    func discoverGo2RTCChannels() async -> [Go2RTCDiscovery.Candidate] {
        guard !isScanningGo2RTC else { return go2rtcScanCandidates }
        isScanningGo2RTC = true
        go2rtcScanStatus = nil
        defer {
            self.isScanningGo2RTC = false
            self.go2rtcScanStatus = nil
        }
        let discovered = await Go2RTCDiscovery.discover { progress in
            Task { @MainActor in
                self.go2rtcScanStatus = Go2RTCScanStatus(
                    stage: progress.phase == .discovering ? .discovering : .verifying,
                    scannedHosts: progress.scannedHosts,
                    totalHosts: progress.totalHosts,
                    foundServers: progress.foundServers,
                    verifiedStreams: progress.verifiedStreams
                )
            }
       }
        var upgraded = false
        for candidate in discovered {
            guard let newChannel = candidate.channel,
                  let index = go2rtcChannels.firstIndex(where: { $0.id == newChannel.id }),
                  go2rtcChannels[index].url != newChannel.url else { continue }
            go2rtcChannels[index] = newChannel
            upgraded = true
        }
        if upgraded {
            Self.saveGo2RTCChannels(go2rtcChannels, to: defaults, key: go2rtcChannelsKey)
            refreshImportedChannels()
        }
        go2rtcScanCandidates = discovered
        return discovered
    }

    func addSelectedGo2RTCChannels(_ selected: [Go2RTCDiscovery.Candidate]) -> Int {
        let additions = selected.compactMap(\.channel)
        guard !additions.isEmpty else { return 0 }
        print("GO2RTC_ADD selected=\(selected.map(\.name).joined(separator: ","))")
        var merged = go2rtcChannels
        let existing = Set(merged.map(\.id))
        let added = additions.filter { !existing.contains($0.id) }
        merged.append(contentsOf: added)
        go2rtcChannels = merged
        Self.saveGo2RTCChannels(merged, to: defaults, key: go2rtcChannelsKey)
        for channel in added {
            deletedChannelIDs.remove(channel.id)
            unavailable.remove(channel.id)
        }
        defaults.set(Array(deletedChannelIDs), forKey: "deletedChannelIDs")
        refreshImportedChannels()
        if !added.isEmpty, let first = added.first {
            prioritizeGo2RTCChannels(ids: added.map(\.id), featured: first.id)
        }
        go2rtcScanCandidates = []
        print("GO2RTC_ADD done added=\(added.count) total=\(merged.count) deleted=\(deletedChannelIDs.sorted())")
        return added.count
    }

    func clearGo2RTCChannels() {
        go2rtcChannels = []
        defaults.removeObject(forKey: go2rtcChannelsKey)
        refreshImportedChannels()
        normalizePage()
    }

    private func prioritizeGo2RTCChannels(ids: [String], featured: String) {
        var order = m3uPriorityOrder.filter { !ids.contains($0) }
        order.insert(contentsOf: ids, at: 0)
        defaults.set(order, forKey: "m3uPriorityOrder")
        defaults.removeObject(forKey: lastM3UFeatureIDKey)
        featuredID = featured
        category = .all
        selectedCountry = "ALL"
        page = 0
        defaults.set(ChannelCategory.all.rawValue, forKey: "category")
    }
    #endif

    private static func loadGo2RTCChannels(from defaults: UserDefaults, key: String) -> [NewsChannel] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([NewsChannel].self, from: data) else { return [] }
        return decoded
    }

    private static func saveGo2RTCChannels(_ channels: [NewsChannel], to defaults: UserDefaults, key: String) {
        guard let data = try? JSONEncoder().encode(channels) else { return }
        defaults.set(data, forKey: key)
    }

    func syncCloudLibraryIfNeeded(force: Bool = false) async {
        guard isCloudLibrarySyncEnabled, !isSyncingCloudLibrary else { return }
        guard CloudLibrarySyncService.hasRequiredEntitlement else {
            // Keep the user's preference enabled. An unsigned simulator cannot access the
            // production container, but turning the switch off made the control appear broken
            // and also discarded the preference that should be used on a signed device.
            cloudLibraryError = CloudLibrarySyncService.unavailableExplanation
            return
        }
        if !force,
           let lastAttempt = defaults.object(forKey: cloudLibraryLastAttemptAtKey) as? Date,
           Date().timeIntervalSince(lastAttempt) < 5 * 60 {
            return
        }

        isSyncingCloudLibrary = true
        defaults.set(Date(), forKey: cloudLibraryLastAttemptAtKey)
        defer { isSyncingCloudLibrary = false }

        do {
            let result = try await CloudLibrarySyncService.shared.synchronize(local: makeCloudLibrarySnapshot())
            switch result {
            case .downloaded(let snapshot):
                try applyCloudLibrarySnapshot(snapshot)
                await syncRemotePlaylistIfNeeded(force: false)
            case .uploaded, .unchanged:
                break
            }
            let now = Date()
            cloudLibraryLastSyncedAt = now
            defaults.set(now, forKey: cloudLibraryLastSyncedAtKey)
            cloudLibraryError = nil
        } catch {
            cloudLibraryError = error.localizedDescription
        }
    }

    func makeCloudLibraryBackup() async throws -> CloudLibraryBackup {
        let snapshot = try await CloudLibrarySyncService.shared.fetchSnapshot()
        let favorites = cloudStore.array(forKey: cloudFavoritesKey) as? [String] ?? []
        return CloudLibraryBackup(
            formatVersion: CloudLibraryBackup.currentFormatVersion,
            containerIdentifier: CloudLibrarySyncService.containerIdentifier,
            recordName: CloudLibrarySyncService.recordName,
            exportedAt: Date(),
            snapshot: snapshot,
            ubiquitousFavorites: favorites
        )
    }

    func restoreCloudLibraryBackup(_ backup: CloudLibraryBackup) async throws {
        guard backup.formatVersion == CloudLibraryBackup.currentFormatVersion,
              backup.containerIdentifier == CloudLibrarySyncService.containerIdentifier,
              backup.recordName == CloudLibrarySyncService.recordName else {
            throw CloudLibrarySyncError.invalidBackup
        }

        cloudLibrarySyncTask?.cancel()
        isSyncingCloudLibrary = true
        defer { isSyncingCloudLibrary = false }

        let restoredSnapshot = backup.snapshot ?? .emptyReset()
        try await CloudLibrarySyncService.shared.replace(snapshot: restoredSnapshot)
        try applyCloudLibrarySnapshot(restoredSnapshot)
        cloudStore.set(
            backup.snapshot == nil ? [String]() : backup.ubiquitousFavorites,
            forKey: cloudFavoritesKey
        )
        cloudStore.synchronize()

        let now = Date()
        cloudLibraryLastSyncedAt = now
        defaults.set(now, forKey: cloudLibraryLastSyncedAtKey)
        cloudLibraryError = nil
    }

    func clearCloudLibraryForTesting() async throws {
        cloudLibrarySyncTask?.cancel()
        isSyncingCloudLibrary = true
        defer { isSyncingCloudLibrary = false }

        try await CloudLibrarySyncService.shared.clear()
        cloudStore.set([String](), forKey: cloudFavoritesKey)
        cloudStore.synchronize()

        // Keep local playlists intact. The cloud record now contains a newer empty snapshot,
        // so other installations download the reset instead of recreating a deleted record.
        isCloudLibrarySyncEnabled = false
        defaults.set(false, forKey: cloudLibraryEnabledKey)
        cloudLibraryLastSyncedAt = nil
        defaults.removeObject(forKey: cloudLibraryLastSyncedAtKey)
        defaults.removeObject(forKey: cloudLibraryLastAttemptAtKey)
        cloudLibraryModifiedAt = .distantPast
        defaults.set(Date.distantPast, forKey: cloudLibraryModifiedAtKey)
        cloudLibraryError = nil
    }

    func selectCategory(_ value: ChannelCategory) {
        category = value
        selectedCountry = "ALL"
        page = 0
        featuredID = nil
        defaults.set(value.rawValue, forKey: "category")
    }

    func selectSourceFilter(_ value: ChannelSourceFilter) {
        sourceFilter = value
        selectedCountry = "ALL"
        page = 0
        featuredID = nil
        defaults.set(value.rawValue, forKey: sourceFilterKey)
    }

    func saveRemoteSyncSettings(_ settings: RemotePlaylistSyncSettings) {
        var normalized = settings
        normalized.sourceURL = normalized.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.reloadIntervalMinutes = min(max(normalized.reloadIntervalMinutes, 1), 24 * 60)
        remoteSyncSettings = normalized
        RemotePlaylistSyncLibrary.save(normalized)
        markCloudLibraryChanged()
    }

    func syncRemotePlaylistIfNeeded(force: Bool = false) async {
        let settings = remoteSyncSettings
        guard settings.isEnabled else { return }
        let trimmed = settings.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !force,
           let lastCheckedAt = settings.lastCheckedAt,
           Date().timeIntervalSince(lastCheckedAt) < TimeInterval(settings.reloadIntervalMinutes * 60) {
            return
        }
        await syncRemotePlaylist(force: force)
    }

    func syncRemotePlaylist(force: Bool = true) async {
        var settings = remoteSyncSettings
        let trimmed = settings.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased()) else {
            settings.lastCheckedAt = Date()
            settings.lastError = M3UImportError.invalidURL.localizedDescription
            saveRemoteSyncSettings(settings)
            return
        }

        guard !isSyncingRemoteM3U else { return }
        isSyncingRemoteM3U = true
        defer { isSyncingRemoteM3U = false }

        do {
            let text = try await Self.downloadPlaylistText(from: url, requestTimeout: 30, resourceTimeout: 45)
            let parsed = Self.parsePlaylist(text, category: .m3u, idPrefix: remotePlaylistID)
            guard !parsed.isEmpty else { throw M3UImportError.noPlayableChannels }

            let signature = Self.contentSignature(for: text)
            let existing = importedPlaylists.first(where: { $0.id == remotePlaylistID })
            // `force` only bypasses the reload interval. The playlist should still refresh
            // only when the remote content actually changes.
            let changed = existing?.content != text || settings.lastContentSignature != signature
            settings.lastCheckedAt = Date()
            settings.lastContentSignature = signature
            settings.lastError = nil

            if changed {
                let record = ImportedPlaylistRecord(
                    id: remotePlaylistID,
                    name: "Remote M3U Sync",
                    sourceURL: trimmed,
                    content: text,
                    channelCount: parsed.count,
                    importedAt: Date()
                )
                importedPlaylists.removeAll { $0.id == remotePlaylistID }
                importedPlaylists.append(record)
                try M3UPlaylistLibrary.save(importedPlaylists)
                settings.lastUpdatedAt = Date()
                remoteSyncSettings = settings
                RemotePlaylistSyncLibrary.save(settings)
                refreshImportedChannels()
                markCloudLibraryChanged()
            } else {
                remoteSyncSettings = settings
                RemotePlaylistSyncLibrary.save(settings)
            }
        } catch {
            settings.lastCheckedAt = Date()
            settings.lastError = error.localizedDescription
            remoteSyncSettings = settings
            RemotePlaylistSyncLibrary.save(settings)
        }
    }

    func importM3U(from rawValue: String) async throws -> Int {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased()) else {
            throw M3UImportError.invalidURL
        }

        isImportingM3U = true
        defer { isImportingM3U = false }

        let text = try await Self.downloadPlaylistText(from: url, requestTimeout: 30, resourceTimeout: 45)

        let existing = importedPlaylists.first(where: { $0.sourceURL == trimmed })
        let playlistID = existing?.id ?? UUID().uuidString
        let parsed = Self.parsePlaylist(text, category: .m3u, idPrefix: playlistID)
        guard !parsed.isEmpty else { throw M3UImportError.noPlayableChannels }

        let headerName = text.components(separatedBy: .newlines)
            .first(where: { $0.hasPrefix("#PLAYLIST:") })?
            .dropFirst("#PLAYLIST:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? "M3U Playlist"
        let record = ImportedPlaylistRecord(
            id: playlistID,
            name: headerName.flatMap { $0.isEmpty ? nil : String($0) } ?? (fallbackName.isEmpty ? "M3U Playlist" : fallbackName),
            sourceURL: trimmed,
            content: text,
            channelCount: parsed.count,
            importedAt: Date()
        )
        importedPlaylists.removeAll { $0.id == playlistID }
        importedPlaylists.append(record)
        try M3UPlaylistLibrary.save(importedPlaylists)
        refreshImportedChannels()
        prioritizeM3UChannel(id: parsed[0].id)
        markCloudLibraryChanged()
        return parsed.count
    }

    func removeImportedPlaylist(_ playlist: ImportedPlaylistRecord) throws {
        importedPlaylists.removeAll { $0.id == playlist.id }
        try M3UPlaylistLibrary.save(importedPlaylists)
        refreshImportedChannels()
        markCloudLibraryChanged()
    }

    func clearImportedPlaylists() throws {
        importedPlaylists.removeAll()
        try M3UPlaylistLibrary.save(importedPlaylists)
        refreshImportedChannels()
        markCloudLibraryChanged()
    }

    #if os(macOS)
    func loadIPTVOrgCatalog(force: Bool = false) async {
        guard !isLoadingCatalog else { return }
        if !force,
           let cached = IPTVOrgCatalogLibrary.load(),
           Date().timeIntervalSince(cached.fetchedAt) < catalogMaxAge {
            catalogChannels = cached.channels
            catalogError = nil
            return
        }

        isLoadingCatalog = true
        catalogError = nil
        defer { isLoadingCatalog = false }

        do {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 180
            configuration.waitsForConnectivity = true
            let session = URLSession(configuration: configuration)
            let channelsData = try await Self.downloadCatalogData("https://iptv-org.github.io/api/channels.json", session: session)
            let streamsData = try await Self.downloadCatalogData("https://iptv-org.github.io/api/streams.json", session: session)
            let feedsData = try await Self.downloadCatalogData("https://iptv-org.github.io/api/feeds.json", session: session)
            let rawChannels = try JSONDecoder().decode([IPTVOrgAPIChannel].self, from: channelsData)
            let rawStreams = try JSONDecoder().decode([IPTVOrgAPIStream].self, from: streamsData)
            let rawFeeds = try JSONDecoder().decode([IPTVOrgAPIFeed].self, from: feedsData)
            let resolved = Self.resolveCatalog(channels: rawChannels, streams: rawStreams, feeds: rawFeeds)
            catalogChannels = resolved
            catalogError = nil
            try? IPTVOrgCatalogLibrary.save(IPTVOrgCatalogCache(fetchedAt: Date(), channels: resolved))
        } catch {
            if let cached = IPTVOrgCatalogLibrary.load() {
                catalogChannels = cached.channels
                catalogError = "目前無法更新，正在使用上次下載的頻道索引。原因：\(Self.catalogErrorMessage(error))"
            } else {
                catalogError = "無法讀取 iptv-org 頻道索引。原因：\(Self.catalogErrorMessage(error))"
            }
        }
    }

    func catalogResults(search: String, country: String, categoryID: String, language: String, minimumQuality: Int = 0) -> [IPTVOrgCatalogChannel] {
        let keyword = search.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        return catalogChannels.filter { channel in
            let matchesSearch = keyword.isEmpty || channel.name.localizedLowercase.contains(keyword) || channel.id.localizedLowercase.contains(keyword)
            let matchesCountry = country == "ALL" || channel.country == country
            let matchesCategory = categoryID == "ALL" || channel.categories.contains(categoryID)
            let matchesLanguage = language == "ALL" || channel.languages.contains(language)
            let matchesQuality = minimumQuality <= 0 || channel.qualityScore >= minimumQuality
            return matchesSearch && matchesCountry && matchesCategory && matchesLanguage && matchesQuality
        }
        .sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    var catalogCountries: [(String, Int)] {
        countCatalogValues { [$0.country] }
    }

    var catalogCategories: [(String, Int)] {
        countCatalogValues { $0.categories }
    }

    var catalogLanguages: [(String, Int)] {
        countCatalogValues { $0.languages }
    }

    func isCatalogChannelAdded(_ channel: IPTVOrgCatalogChannel) -> Bool {
        let marker = "tvg-id=\"iptv-org:\(channel.id)\""
        return importedPlaylists.contains { $0.id == discoveredPlaylistID && $0.content.contains(marker) }
    }

    func addCatalogChannel(_ channel: IPTVOrgCatalogChannel) throws {
        guard !isCatalogChannelAdded(channel) else { return }
        let entry = Self.makeCatalogM3UEntry(channel)
        if let index = importedPlaylists.firstIndex(where: { $0.id == discoveredPlaylistID }) {
            importedPlaylists[index].content += "\n\(entry)"
            importedPlaylists[index].channelCount += 1
            importedPlaylists[index].importedAt = Date()
        } else {
            importedPlaylists.append(ImportedPlaylistRecord(
                id: discoveredPlaylistID,
                name: "從 iptv-org 探索加入",
                sourceURL: "iptv-org://discoveries",
                content: "#EXTM3U\n#PLAYLIST:IPTV.org Discoveries\n\(entry)",
                channelCount: 1,
                importedAt: Date()
            ))
        }
        try M3UPlaylistLibrary.save(importedPlaylists)
        refreshImportedChannels()
        prioritizeM3UChannel(id: "m3u:\(discoveredPlaylistID):iptv-org:\(channel.id)")
        markCloudLibraryChanged()
    }
    #endif

    func selectMode(_ value: WallMode) {
        mode = value
        page = 0
        defaults.set(value.rawValue, forKey: "mode")
    }

    func selectCountry(_ value: String) {
        selectedCountry = value
        page = 0
        featuredID = nil
    }

    func changePage(_ delta: Int) {
        page = (page + delta + pageCount) % pageCount
    }

    func center(_ channel: NewsChannel) {
        if channel.category == .m3u {
            featureM3UChannelWithoutReordering(id: channel.id)
        } else {
            featuredID = channel.id
            defaults.removeObject(forKey: lastM3UFeatureIDKey)
        }
    }

    func toggleFavorite(_ channel: NewsChannel) {
        if isFavorite(channel) {
            favorites = favorites.filter { !matchesFavoriteIdentifier($0, channel: channel) }
            favoriteOrder.removeAll { matchesFavoriteIdentifier($0, channel: channel) }
        } else {
            let identifier = favoriteIdentifier(for: channel)
            favorites.insert(identifier)
            favoriteOrder.append(identifier)
        }
        persistFavorites()
    }

    func moveFavorite(_ channel: NewsChannel, by offset: Int) {
        guard isFavorite(channel), offset != 0 else { return }
        favoriteOrder = normalizedFavoriteOrder()
        let identifier = favoriteIdentifier(for: channel)
        guard let current = favoriteOrder.firstIndex(of: identifier) else { return }
        let destination = min(max(0, current + offset), favoriteOrder.count - 1)
        guard destination != current else { return }
        favoriteOrder.swapAt(current, destination)
        persistFavorites()
        normalizePage()
    }

    func canMoveFavorite(_ channel: NewsChannel, by offset: Int) -> Bool {
        let order = normalizedFavoriteOrder()
        guard let current = order.firstIndex(of: favoriteIdentifier(for: channel)) else { return false }
        let destination = current + offset
        return order.indices.contains(destination)
    }

    func channelOrderSnapshot(for category: ChannelCategory) -> [String] {
        category == .favorites ? normalizedFavoriteOrder() : normalizedAllChannelOrder()
    }

    func restoreChannelOrder(_ snapshot: [String], for category: ChannelCategory) {
        if category == .favorites {
            favoriteOrder = snapshot
            persistFavorites()
        } else {
            defaults.set(snapshot, forKey: "m3uPriorityOrder")
            markCloudLibraryChanged()
        }
        normalizePage()
    }

    func swapChannelOrder(_ first: NewsChannel, with second: NewsChannel, in category: ChannelCategory) {
        guard first.id != second.id else { return }

        if category == .favorites {
            var order = normalizedFavoriteOrder()
            let firstID = favoriteIdentifier(for: first)
            let secondID = favoriteIdentifier(for: second)
            guard let firstIndex = order.firstIndex(of: firstID),
                  let secondIndex = order.firstIndex(of: secondID) else { return }
            order.swapAt(firstIndex, secondIndex)
            favoriteOrder = order
            persistFavorites()
        } else {
            var order = normalizedAllChannelOrder()
            guard let firstIndex = order.firstIndex(of: first.id),
                  let secondIndex = order.firstIndex(of: second.id) else { return }
            order.swapAt(firstIndex, secondIndex)
            defaults.set(order, forKey: "m3uPriorityOrder")
            markCloudLibraryChanged()
        }

        if let movedIndex = filteredChannels.firstIndex(where: { $0.id == first.id }) {
            page = movedIndex / mode.pageSize
        } else {
            normalizePage()
        }
    }

    func isFavorite(_ channel: NewsChannel) -> Bool {
        favorites.contains { matchesFavoriteIdentifier($0, channel: channel) }
    }

    func markUnavailable(_ channel: NewsChannel) {
        guard channel.category != .m3u else { return }
        unavailable.insert(channel.id)
        if featuredID == channel.id { featuredID = nil }
        normalizePage()
    }

    func deleteChannel(_ channel: NewsChannel) {
        deletedChannelIDs.insert(channel.id)
        if channel.category == .go2rtc {
            go2rtcChannels.removeAll { $0.id == channel.id }
            Self.saveGo2RTCChannels(go2rtcChannels, to: defaults, key: go2rtcChannelsKey)
        }
        favorites = favorites.filter { !matchesFavoriteIdentifier($0, channel: channel) }
        favoriteOrder.removeAll { matchesFavoriteIdentifier($0, channel: channel) }
        unavailable.remove(channel.id)
        if featuredID == channel.id { featuredID = nil }
        if defaults.string(forKey: lastM3UFeatureIDKey) == channel.id {
            defaults.removeObject(forKey: lastM3UFeatureIDKey)
        }
        let priorityOrder = m3uPriorityOrder.filter { $0 != channel.id }
        defaults.set(priorityOrder, forKey: "m3uPriorityOrder")
        defaults.set(Array(deletedChannelIDs), forKey: "deletedChannelIDs")
        persistFavorites()
        normalizePage()
    }

    private func normalizePage() {
        page = min(page, max(0, pageCount - 1))
    }

    private func favoriteIdentifier(for channel: NewsChannel) -> String {
        channel.id
    }

    private func matchesFavoriteIdentifier(_ identifier: String, channel: NewsChannel) -> Bool {
        identifier == channel.id
    }

    private func setupCloudFavoritesSync() {
        cloudStore.synchronize()
        if let cloudFavorites = cloudStore.array(forKey: cloudFavoritesKey) as? [String] {
            favorites = Set(cloudFavorites)
            favoriteOrder = cloudFavorites
            defaults.set(cloudFavorites, forKey: "favorites")
            defaults.set(cloudFavorites, forKey: "favoriteOrder")
        } else {
            cloudStore.set(Array(favorites), forKey: cloudFavoritesKey)
            cloudStore.synchronize()
        }

        cloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloudStore,
            queue: .main
        ) { [weak self] notification in
            guard let changedKeys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String],
                  changedKeys.contains(self?.cloudFavoritesKey ?? "") else { return }
            Task { @MainActor in self?.applyCloudFavorites() }
        }
    }

    private func applyCloudFavorites() {
        guard let cloudFavorites = cloudStore.array(forKey: cloudFavoritesKey) as? [String] else { return }
        favorites = Set(cloudFavorites)
        favoriteOrder = cloudFavorites
        defaults.set(cloudFavorites, forKey: "favorites")
        defaults.set(cloudFavorites, forKey: "favoriteOrder")
        normalizePage()

        // The device that changed favorites already updates the CloudKit snapshot. Marking an
        // externally received KVS value as a new library edit can re-upload stale playlists
        // after another device has reset the cloud library.
        guard isCloudLibrarySyncEnabled else { return }
        cloudLibrarySyncTask?.cancel()
        cloudLibrarySyncTask = Task { [weak self] in
            await self?.syncCloudLibraryIfNeeded(force: true)
        }
    }

    private func persistFavorites() {
        let values = normalizedFavoriteOrder()
        favoriteOrder = values
        defaults.set(values, forKey: "favorites")
        defaults.set(values, forKey: "favoriteOrder")
        cloudStore.set(values, forKey: cloudFavoritesKey)
        cloudStore.synchronize()
        markCloudLibraryChanged()
    }

    private func normalizedFavoriteOrder() -> [String] {
        var seen = Set<String>()
        var result = favoriteOrder.filter { favorites.contains($0) && seen.insert($0).inserted }
        result.append(contentsOf: favorites.filter { seen.insert($0).inserted }.sorted())
        return result
    }

    private func normalizedAllChannelOrder() -> [String] {
        let availableIDs = Set(
            channels
                .filter { !unavailable.contains($0.id) && !deletedChannelIDs.contains($0.id) }
                .map(\.id)
        )
        var seen = Set<String>()
        var result = m3uPriorityOrder.filter {
            availableIDs.contains($0) && seen.insert($0).inserted
        }
        result.append(contentsOf: channels.compactMap { channel in
            guard availableIDs.contains(channel.id), seen.insert(channel.id).inserted else { return nil }
            return channel.id
        })
        return result
    }

    private func makeCloudLibrarySnapshot() -> CloudLibrarySnapshot {
        return CloudLibrarySnapshot(
            schemaVersion: 2,
            modifiedAt: cloudLibraryModifiedAt,
            // Include the current remote playlist content as well as manually imported
            // playlists so a second device can display the same wall immediately.
            playlists: importedPlaylists,
            favoriteOrder: normalizedFavoriteOrder(),
            deletedChannelIDs: deletedChannelIDs.sorted(),
            m3uPriorityOrder: m3uPriorityOrder,
            remoteSyncSettings: remoteSyncSettings
        )
    }

    private func applyCloudLibrarySnapshot(_ snapshot: CloudLibrarySnapshot) throws {
        isApplyingCloudLibrarySnapshot = true
        defer { isApplyingCloudLibrarySnapshot = false }

        // iCloud snapshots are part of the user's private library. Restore them verbatim on
        // every platform; tvOS compliance is enforced by omitting bundled/public discovery
        // entry points from the app, not by deleting previously saved user data.
        importedPlaylists = snapshot.playlists
        try M3UPlaylistLibrary.save(importedPlaylists)

        favoriteOrder = snapshot.favoriteOrder
        favorites = Set(snapshot.favoriteOrder)
        deletedChannelIDs = Set(snapshot.deletedChannelIDs)
        remoteSyncSettings = snapshot.remoteSyncSettings
        cloudLibraryModifiedAt = snapshot.modifiedAt

        defaults.set(snapshot.favoriteOrder, forKey: "favorites")
        defaults.set(snapshot.favoriteOrder, forKey: "favoriteOrder")
        defaults.set(snapshot.deletedChannelIDs, forKey: "deletedChannelIDs")
        defaults.set(snapshot.m3uPriorityOrder, forKey: "m3uPriorityOrder")
        defaults.set(snapshot.modifiedAt, forKey: cloudLibraryModifiedAtKey)
        RemotePlaylistSyncLibrary.save(snapshot.remoteSyncSettings)
        cloudStore.set(snapshot.favoriteOrder, forKey: cloudFavoritesKey)
        cloudStore.synchronize()
        refreshImportedChannels()
    }

    private func markCloudLibraryChanged() {
        guard !isApplyingCloudLibrarySnapshot else { return }
        cloudLibraryModifiedAt = Date()
        defaults.set(cloudLibraryModifiedAt, forKey: cloudLibraryModifiedAtKey)
        guard isCloudLibrarySyncEnabled else { return }

        cloudLibrarySyncTask?.cancel()
        cloudLibrarySyncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.syncCloudLibraryIfNeeded(force: true)
        }
    }

    #if os(macOS)
    private func countCatalogValues(_ values: (IPTVOrgCatalogChannel) -> [String]) -> [(String, Int)] {
        var counts: [String: Int] = [:]
        for channel in catalogChannels {
            for value in values(channel) where !value.isEmpty {
                counts[value, default: 0] += 1
            }
        }
        return counts.sorted { lhs, rhs in
            lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
        }
    }
    #endif

    private func importedChannels() -> [NewsChannel] {
        importedPlaylists.flatMap { playlist in
            Self.parsePlaylist(playlist.content, category: .m3u, idPrefix: playlist.id)
        }
    }

    #if os(macOS)
    private static var bundledStarterChannels: [NewsChannel] {
        parsePlaylist(bundledStarterM3U, category: .m3u, idPrefix: starterPlaylistID)
    }
    #endif

    private func prioritizeM3UChannel(id: String) {
        featuredID = id
        recordM3UPriority(id: id)
        category = .all
        selectedCountry = "ALL"
        page = 0
        defaults.set(ChannelCategory.all.rawValue, forKey: "category")
    }

    private func featureM3UChannelWithoutReordering(id: String) {
        featuredID = id
        defaults.set(id, forKey: lastM3UFeatureIDKey)
    }

    private var m3uPriorityOrder: [String] {
        defaults.stringArray(forKey: "m3uPriorityOrder") ?? []
    }

    private func recordM3UPriority(id: String) {
        var order = m3uPriorityOrder.filter { $0 != id }
        order.insert(id, at: 0)
        defaults.set(Array(order.prefix(100)), forKey: "m3uPriorityOrder")
        defaults.set(id, forKey: lastM3UFeatureIDKey)
        markCloudLibraryChanged()
    }

    #if os(macOS)
    private static func downloadCatalogData(_ string: String, session: URLSession) async throws -> Data {
        guard let url = URL(string: string) else { throw URLError(.badURL) }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func catalogErrorMessage(_ error: Error) -> String {
        if let decodingError = error as? DecodingError {
            switch decodingError {
            case .typeMismatch(_, let context),
                 .valueNotFound(_, let context),
                 .keyNotFound(_, let context),
                 .dataCorrupted(let context):
                let path = context.codingPath.map { $0.stringValue }.joined(separator: ".")
                return "資料格式解析失敗：\(path) \(context.debugDescription)"
            @unknown default:
                return "資料格式解析失敗。"
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return "讀取被系統中斷，請按「重新整理」再試一次。"
            case .timedOut:
                return "連線逾時，請稍後重試。"
            case .notConnectedToInternet:
                return "Apple TV 目前沒有網路連線。"
            case .cannotFindHost, .cannotConnectToHost:
                return "無法連上 iptv-org 伺服器。"
            default:
                return urlError.localizedDescription
            }
        }
        return error.localizedDescription
    }
    #endif

    private static func downloadPlaylistText(from url: URL, requestTimeout: TimeInterval, resourceTimeout: TimeInterval) async throws -> String {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        do {
            let (data, response) = try await URLSession(configuration: configuration).data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw M3UImportError.downloadFailed
            }
            guard let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else {
                throw M3UImportError.unreadableText
            }
            return text
        } catch let error as M3UImportError {
            throw error
        } catch {
            throw M3UImportError.downloadFailed
        }
    }

    private static func contentSignature(for text: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "\(text.utf8.count)-\(String(hash, radix: 16))"
    }

    #if os(macOS)
    private static func resolveCatalog(
        channels: [IPTVOrgAPIChannel],
        streams: [IPTVOrgAPIStream],
        feeds: [IPTVOrgAPIFeed]
    ) -> [IPTVOrgCatalogChannel] {
        let channelByID = Dictionary(uniqueKeysWithValues: channels.map { ($0.id, $0) })
        var languagesByChannel: [String: Set<String>] = [:]
        var languagesByFeed: [String: Set<String>] = [:]
        for feed in feeds {
            guard !feed.languages.isEmpty else { continue }
            languagesByChannel[feed.channel, default: []].formUnion(feed.languages)
            languagesByFeed["\(feed.channel):\(feed.id)", default: []].formUnion(feed.languages)
        }

        var bestStreams: [String: IPTVOrgAPIStream] = [:]
        for stream in streams {
            guard let channelID = stream.channel,
                  let channel = channelByID[channelID],
                  !channel.is_nsfw,
                  channel.closed == nil,
                  stream.user_agent == nil,
                  stream.referrer == nil,
                  stream.label?.localizedCaseInsensitiveContains("geo-blocked") != true,
                  stream.url.localizedCaseInsensitiveContains(".m3u8") else { continue }
            if let current = bestStreams[channelID] {
                if stream.qualityScore > current.qualityScore { bestStreams[channelID] = stream }
            } else {
                bestStreams[channelID] = stream
            }
        }

        return bestStreams.compactMap { channelID, stream in
            guard let channel = channelByID[channelID] else { return nil }
            let languages = stream.feed.flatMap { languagesByFeed["\(channelID):\($0)"] }
                ?? languagesByChannel[channelID]
                ?? []
            return IPTVOrgCatalogChannel(
                id: channelID,
                name: channel.name,
                country: channel.country,
                categories: channel.categories,
                languages: languages.sorted(),
                streamURL: stream.url,
                quality: stream.quality
            )
        }
    }

    private static func makeCatalogM3UEntry(_ channel: IPTVOrgCatalogChannel) -> String {
        let safeName = channel.name.replacingOccurrences(of: "\"", with: "'")
        let safeCategories = channel.categories.joined(separator: ",")
        return "#EXTINF:-1 tvg-id=\"iptv-org:\(channel.id)\" tvg-country=\"\(channel.country)\" group-title=\"IPTV.org 探索\" tvg-type=\"\(safeCategories)\",\(safeName)\n\(channel.streamURL)"
    }
    #endif

    private func refreshImportedChannels() {
        channels = combinedChannels()
        unavailable = unavailable.filter { id in channels.contains(where: { $0.id == id }) }
        deletedChannelIDs = deletedChannelIDs.filter { id in channels.contains(where: { $0.id == id }) }
        defaults.set(Array(deletedChannelIDs), forKey: "deletedChannelIDs")
        normalizePage()
    }

    private func combinedChannels() -> [NewsChannel] {
        let source = importedChannels()
        var seen = Set<String>()
        var result = source.filter { seen.insert($0.id).inserted }
        result.append(contentsOf: go2rtcChannels.filter { seen.insert($0.id).inserted })
        return result
    }

    nonisolated private static func parsePlaylist(
        _ text: String,
        category: ChannelCategory,
        idPrefix: String? = nil
    ) -> [NewsChannel] {
        let lines = text.components(separatedBy: .newlines)
        var result: [NewsChannel] = []

        for index in lines.indices where lines[index].hasPrefix("#EXTINF:") {
            let info = lines[index]
            guard let urlLine = lines.dropFirst(index + 1).first(where: { !$0.isEmpty && !$0.hasPrefix("#") }) else { continue }
            let urlText = urlLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: urlText),
                  ["http", "https"].contains(url.scheme?.lowercased()) else { continue }

            let sourceID = attribute("tvg-id", in: info) ?? "channel-\(index)"
            let logo = attribute("tvg-logo", in: info).flatMap(URL.init(string:))
            let name = info.split(separator: ",", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            guard !name.isEmpty, !name.localizedCaseInsensitiveContains("[Geo-blocked]") else { continue }

            let country: String
            if let listedCountry = attribute("tvg-country", in: info), listedCountry.count >= 2 {
                country = String(listedCountry.prefix(2)).uppercased()
            } else if let match = sourceID.range(of: #"\.([A-Za-z]{2})(?:@|$)"#, options: .regularExpression) {
                country = String(sourceID[match]).dropFirst().prefix(2).uppercased()
            } else {
                country = "INT"
            }
            result.append(NewsChannel(
                id: "\(category.rawValue):\(idPrefix.map { "\($0):" } ?? "")\(sourceID)",
                name: name,
                url: url,
                logoURL: logo,
                country: country,
                category: category
            ))
        }
        return result
    }

    nonisolated private static func attribute(_ name: String, in text: String) -> String? {
        guard let range = text.range(of: "\(name)=\"") else { return nil }
        let rest = text[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    nonisolated private static func prioritySort(_ lhs: NewsChannel, _ rhs: NewsChannel) -> Bool {
        let priority = ["Al Jazeera English", "DW English", "France 24 English", "NHK World-Japan", "Euronews English", "Sky News", "ABC News Live", "CBS News", "NBC News NOW", "Arirang TV", "TRT World"]
        let li = priority.firstIndex(where: { lhs.name.hasPrefix($0) }) ?? priority.count
        let ri = priority.firstIndex(where: { rhs.name.hasPrefix($0) }) ?? priority.count
        return li == ri ? lhs.name < rhs.name : li < ri
    }
}
