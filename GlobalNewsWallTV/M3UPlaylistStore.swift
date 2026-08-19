import Foundation
import CloudKit
import Security

struct ImportedPlaylistRecord: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var sourceURL: String
    var content: String
    var channelCount: Int
    var importedAt: Date
}

struct RemotePlaylistSyncSettings: Codable, Hashable {
    var isEnabled: Bool
    var sourceURL: String
    var reloadIntervalMinutes: Int
    var lastContentSignature: String?
    var lastCheckedAt: Date?
    var lastUpdatedAt: Date?
    var lastError: String?

    static let disabled = RemotePlaylistSyncSettings(
        isEnabled: false,
        sourceURL: "",
        reloadIntervalMinutes: 10,
        lastContentSignature: nil,
        lastCheckedAt: nil,
        lastUpdatedAt: nil,
        lastError: nil
    )
}

struct CloudLibrarySnapshot: Codable, Hashable {
    let schemaVersion: Int
    var modifiedAt: Date
    var playlists: [ImportedPlaylistRecord]
    var favoriteOrder: [String]
    var deletedChannelIDs: [String]
    var m3uPriorityOrder: [String]
    var remoteSyncSettings: RemotePlaylistSyncSettings

    static func emptyReset(modifiedAt: Date = Date()) -> CloudLibrarySnapshot {
        CloudLibrarySnapshot(
            schemaVersion: 2,
            modifiedAt: modifiedAt,
            playlists: [],
            favoriteOrder: [],
            deletedChannelIDs: [],
            m3uPriorityOrder: [],
            remoteSyncSettings: .disabled
        )
    }
}

struct CloudLibraryBackup: Codable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let containerIdentifier: String
    let recordName: String
    let exportedAt: Date
    let snapshot: CloudLibrarySnapshot?
    let ubiquitousFavorites: [String]
}

enum CloudLibrarySyncResult {
    case downloaded(CloudLibrarySnapshot)
    case uploaded
    case unchanged
}

enum CloudLibrarySyncError: LocalizedError {
    case iCloudUnavailable
    case noICloudAccount
    case restricted
    case temporarilyUnavailable
    case invalidCloudData
    case invalidBackup

    var errorDescription: String? {
        switch self {
        case .iCloudUnavailable:
            return "目前無法連接 iCloud，播放清單仍會保留在這台裝置。"
        case .noICloudAccount:
            return "這台裝置尚未登入 iCloud，無法跨裝置同步播放清單。"
        case .restricted:
            return "這台裝置的 iCloud 功能受到限制。"
        case .temporarilyUnavailable:
            return "iCloud 暫時無法使用，稍後會自動重試。"
        case .invalidCloudData:
            return "iCloud 中的播放清單資料無法辨識。"
        case .invalidBackup:
            return "這不是 IPTV Wall Player 的有效 iCloud 備份檔。"
        }
    }
}

actor CloudLibrarySyncService {
    static let shared = CloudLibrarySyncService()
    static let containerIdentifier = "iCloud.com.neo99.IPTVWall"
    static let recordName = "user-library-v1"

    static var unavailableExplanation: String? {
        guard !hasRequiredEntitlement else { return nil }
#if targetEnvironment(simulator)
        return "iOS 模擬器無法連接正式的具名 CloudKit 容器；請在已簽章的 iPhone、iPad 實機或 TestFlight 版本測試同步。"
#else
        return CloudLibrarySyncError.iCloudUnavailable.localizedDescription
#endif
    }

    static var hasRequiredEntitlement: Bool {
#if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let identifiers = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.developer.icloud-container-identifiers" as CFString,
                nil
              ) as? [String] else {
            return false
        }
        return identifiers.contains("iCloud.com.neo99.IPTVWall")
#elseif targetEnvironment(simulator)
        // Named production containers are unavailable to unsigned simulator builds.
        return false
#else
        // Device archives are validated after export to ensure this entitlement exists.
        return true
#endif
    }

    private let container = CKContainer(identifier: CloudLibrarySyncService.containerIdentifier)
    private let recordID = CKRecord.ID(recordName: CloudLibrarySyncService.recordName)
    private let recordType = "IPTVWallLibrary"

    func fetchSnapshot() async throws -> CloudLibrarySnapshot? {
        try await verifyAccount()

        do {
            let record = try await container.privateCloudDatabase.record(for: recordID)
            return try snapshot(from: record)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        } catch {
            throw map(error)
        }
    }

    func replace(snapshot: CloudLibrarySnapshot?) async throws {
        try await verifyAccount()

        guard let snapshot else {
            try await replaceWithEmptyReset()
            return
        }

        do {
            let record: CKRecord?
            do {
                record = try await container.privateCloudDatabase.record(for: recordID)
            } catch let error as CKError where error.code == .unknownItem {
                record = nil
            }
            try await upload(snapshot, using: record)
        } catch {
            throw map(error)
        }
    }

    func clear() async throws {
        try await verifyAccount()

        try await replaceWithEmptyReset()
    }

    private func replaceWithEmptyReset() async throws {
        let snapshot = CloudLibrarySnapshot.emptyReset()

        do {
            let record: CKRecord?
            do {
                record = try await container.privateCloudDatabase.record(for: recordID)
            } catch let error as CKError where error.code == .unknownItem {
                record = nil
            }
            try await upload(snapshot, using: record)
        } catch let error as CKError where error.code == .unknownItem {
            try await upload(snapshot, using: nil)
        } catch {
            throw map(error)
        }
    }

    func synchronize(local: CloudLibrarySnapshot) async throws -> CloudLibrarySyncResult {
        try await verifyAccount()

        do {
            let record = try await container.privateCloudDatabase.record(for: recordID)
            let remote = try snapshot(from: record)
            // An empty local library commonly means a fresh install or that an older
            // tvOS build filtered the downloaded payload. Preserve private iCloud data
            // whenever the cloud record still contains user playlists.
            if local.playlists.isEmpty && !remote.playlists.isEmpty {
                return .downloaded(remote)
            }
            if remote.modifiedAt > local.modifiedAt {
                return .downloaded(remote)
            }
            if local.modifiedAt > remote.modifiedAt {
                try await upload(local, using: record)
                return .uploaded
            }
            if remote.schemaVersion < local.schemaVersion {
                try await upload(local, using: record)
                return .uploaded
            }
            // A previous app version may have transformed the downloaded snapshot while
            // retaining its modification date. When timestamps match but payloads differ,
            // treat the private iCloud record as the source of truth and repair local data.
            if remote != local {
                return .downloaded(remote)
            }
            return .unchanged
        } catch let error as CKError where error.code == .unknownItem {
            try await upload(local, using: nil)
            return .uploaded
        } catch let error as CKError where error.code == .serverRecordChanged {
            let record = try await container.privateCloudDatabase.record(for: recordID)
            let remote = try snapshot(from: record)
            if remote.modifiedAt >= local.modifiedAt {
                return .downloaded(remote)
            }
            try await upload(local, using: record)
            return .uploaded
        } catch {
            throw map(error)
        }
    }

    private func verifyAccount() async throws {
        switch try await container.accountStatus() {
        case .available:
            return
        case .noAccount:
            throw CloudLibrarySyncError.noICloudAccount
        case .restricted:
            throw CloudLibrarySyncError.restricted
        case .couldNotDetermine, .temporarilyUnavailable:
            throw CloudLibrarySyncError.temporarilyUnavailable
        @unknown default:
            throw CloudLibrarySyncError.iCloudUnavailable
        }
    }

    private func snapshot(from record: CKRecord) throws -> CloudLibrarySnapshot {
        guard let asset = record["payload"] as? CKAsset,
              let fileURL = asset.fileURL,
              let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(CloudLibrarySnapshot.self, from: data) else {
            throw CloudLibrarySyncError.invalidCloudData
        }
        return snapshot
    }

    private func upload(_ snapshot: CloudLibrarySnapshot, using existingRecord: CKRecord?) async throws {
        let record = existingRecord ?? CKRecord(recordType: recordType, recordID: recordID)
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("iptv-wall-library-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        try JSONEncoder().encode(snapshot).write(to: temporaryURL, options: .atomic)
        record["schemaVersion"] = snapshot.schemaVersion as CKRecordValue
        record["modifiedAt"] = snapshot.modifiedAt as CKRecordValue
        record["payload"] = CKAsset(fileURL: temporaryURL)
        _ = try await container.privateCloudDatabase.save(record)
    }

    private func map(_ error: Error) -> Error {
        guard let cloudError = error as? CKError else { return error }
        switch cloudError.code {
        case .notAuthenticated:
            return CloudLibrarySyncError.noICloudAccount
        case .permissionFailure:
            return CloudLibrarySyncError.restricted
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return CloudLibrarySyncError.temporarilyUnavailable
        default:
            return cloudError
        }
    }
}

#if os(macOS)
struct IPTVOrgCatalogChannel: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let country: String
    let categories: [String]
    let languages: [String]
    let streamURL: String
    let quality: String?

    var qualityScore: Int {
        Int(quality?.filter(\.isNumber) ?? "") ?? 0
    }
}

struct IPTVOrgCatalogCache: Codable {
    let fetchedAt: Date
    let channels: [IPTVOrgCatalogChannel]
}

enum IPTVOrgCatalogLibrary {
    private static var fileURL: URL? {
        let manager = FileManager.default
        let supportDirectory = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.urls(for: .libraryDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Application Support", isDirectory: true)
        return supportDirectory?
            .appendingPathComponent("IPTVWall", isDirectory: true)
            .appendingPathComponent("iptv-org-catalog.json")
    }

    static func load() -> IPTVOrgCatalogCache? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(IPTVOrgCatalogCache.self, from: data)
    }

    static func save(_ cache: IPTVOrgCatalogCache) throws {
        guard let fileURL else { throw M3UImportError.storageUnavailable }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(cache).write(to: fileURL, options: .atomic)
    }
}
#endif

enum M3UPlaylistLibrary {
    private static var fileURLs: [URL] {
        let manager = FileManager.default
        // tvOS apps cannot reliably write to Documents. Its per-app Caches directory is writable
        // and is the supported fallback when Application Support is unavailable on a development build.
        let cacheDirectory = manager.urls(for: .cachesDirectory, in: .userDomainMask).first
        let supportDirectory = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let librarySupportDirectory = manager.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Application Support", isDirectory: true)
        return [cacheDirectory, supportDirectory, librarySupportDirectory]
            .compactMap { $0 }
            .map {
                $0.appendingPathComponent("IPTVWall", isDirectory: true)
                    .appendingPathComponent("imported-playlists.json")
            }
    }

    static func load() -> [ImportedPlaylistRecord] {
        for fileURL in fileURLs {
            guard let data = try? Data(contentsOf: fileURL),
                  let playlists = try? JSONDecoder().decode([ImportedPlaylistRecord].self, from: data) else { continue }
            return playlists
        }
        return []
    }

    static func save(_ playlists: [ImportedPlaylistRecord]) throws {
        let data = try JSONEncoder().encode(playlists)
        var lastError: Error?
        for fileURL in fileURLs {
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: fileURL, options: .atomic)
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? M3UImportError.storageUnavailable
    }
}

enum RemotePlaylistSyncLibrary {
    private static let key = "remotePlaylistSyncSettings.v1"

    static func load() -> RemotePlaylistSyncSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(RemotePlaylistSyncSettings.self, from: data) else {
            return .disabled
        }
        return settings
    }

    static func save(_ settings: RemotePlaylistSyncSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

enum M3UImportError: LocalizedError {
    case invalidURL
    case downloadFailed
    case unreadableText
    case noPlayableChannels
    case storageUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "請輸入以 http:// 或 https:// 開頭的 M3U 網址。"
        case .downloadFailed: return "無法下載這份播放清單，請檢查網址與網路。"
        case .unreadableText: return "播放清單不是可辨識的文字檔。"
        case .noPlayableChannels: return "播放清單中沒有找到可播放的頻道。"
        case .storageUnavailable: return "Apple TV 無法建立播放清單儲存位置。"
        }
    }
}
