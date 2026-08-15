import Foundation
import HomeKit

final class HomeKitCameraSession: NSObject, HMCameraStreamControlDelegate, HMCameraSnapshotControlDelegate {
    private let control: HMCameraStreamControl
    private let snapshotControl: HMCameraSnapshotControl?
    private let liveViews = NSHashTable<HMCameraView>.weakObjects()
    private let snapshotViews = NSHashTable<HMCameraView>.weakObjects()
    private let audibleViews = NSHashTable<HMCameraView>.weakObjects()
    private var snapshotTimer: Timer?

    init(control: HMCameraStreamControl, snapshotControl: HMCameraSnapshotControl?) {
        self.control = control
        self.snapshotControl = snapshotControl
        super.init()
        control.delegate = self
        snapshotControl?.delegate = self
    }

    func attach(_ view: HMCameraView, muted: Bool) {
        if muted, let snapshotControl {
            snapshotViews.add(view)
            if let snapshot = snapshotControl.mostRecentSnapshot { view.cameraSource = snapshot }
            scheduleSnapshotRefresh()
        } else {
            liveViews.add(view)
            setMuted(muted, for: view)
            if let stream = control.cameraStream { view.cameraSource = stream }
            control.startStream()
        }
    }

    func setMuted(_ muted: Bool, for view: HMCameraView) {
        if muted { audibleViews.remove(view) } else { audibleViews.add(view) }
        updateAudio()
    }

    func detach(_ view: HMCameraView) {
        liveViews.remove(view)
        snapshotViews.remove(view)
        audibleViews.remove(view)
        view.cameraSource = nil
        if liveViews.allObjects.isEmpty { control.stopStream() } else { updateAudio() }
        if snapshotViews.allObjects.isEmpty {
            snapshotTimer?.invalidate()
            snapshotTimer = nil
        }
    }

    func resume() {
        if !liveViews.allObjects.isEmpty { control.startStream() }
        if !snapshotViews.allObjects.isEmpty { requestSnapshot() }
    }

    func cameraStreamControlDidStartStream(_ cameraStreamControl: HMCameraStreamControl) {
        guard let stream = cameraStreamControl.cameraStream else { return }
        for view in liveViews.allObjects { view.cameraSource = stream }
        updateAudio()
    }

    func cameraStreamControl(
        _ cameraStreamControl: HMCameraStreamControl,
        didStopStreamWithError error: (any Error)?
    ) {
        guard error != nil, !liveViews.allObjects.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.control.startStream()
        }
    }

    func cameraSnapshotControl(
        _ cameraSnapshotControl: HMCameraSnapshotControl,
        didTake snapshot: HMCameraSnapshot?,
        error: (any Error)?
    ) {
        guard let snapshot else { return }
        for view in snapshotViews.allObjects { view.cameraSource = snapshot }
    }

    func cameraSnapshotControlDidUpdateMostRecentSnapshot(_ cameraSnapshotControl: HMCameraSnapshotControl) {
        guard let snapshot = cameraSnapshotControl.mostRecentSnapshot else { return }
        for view in snapshotViews.allObjects { view.cameraSource = snapshot }
    }

    private func updateAudio() {
        let setting: HMCameraAudioStreamSetting = audibleViews.allObjects.isEmpty ? .muted : .incomingAudioAllowed
        control.cameraStream?.updateAudioStreamSetting(setting) { _ in }
    }

    private func scheduleSnapshotRefresh() {
        guard snapshotTimer == nil else { return }
        let stagger = Double(abs(control.hash) % 60) / 10
        DispatchQueue.main.asyncAfter(deadline: .now() + stagger) { [weak self] in
            guard let self, !self.snapshotViews.allObjects.isEmpty else { return }
            self.requestSnapshot()
            self.snapshotTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                self?.requestSnapshot()
            }
        }
    }

    private func requestSnapshot() {
        snapshotControl?.takeSnapshot()
    }
}

@MainActor
final class HomeKitCameraDiscovery: NSObject, HMHomeManagerDelegate {
    static let shared = HomeKitCameraDiscovery()

    private let manager = HMHomeManager()
    private var sessions: [String: HomeKitCameraSession] = [:]

    private override init() {
        super.init()
        manager.delegate = self
    }

    func discover() async -> [NewsChannel] {
        // The HomeKit database and camera profiles arrive asynchronously. Give
        // the home hub enough time to wake accessories before declaring it empty.
        for _ in 0..<60 {
            let channels = currentChannels()
            if !channels.isEmpty { return channels }
            if manager.authorizationStatus.contains(.determined),
               !manager.authorizationStatus.contains(.authorized) {
                return []
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return currentChannels()
    }

    func streamSession(for channelID: String) -> HomeKitCameraSession? {
        sessions[channelID]
    }

    func emptyStateMessage() -> String {
        guard manager.authorizationStatus.contains(.authorized) else {
            return "Apple TV 尚未允許家庭資料。請到「設定 → 一般 → 隱私權與安全性 → Apple 家庭」開啟 IPTV Wall Player。"
        }
        guard !manager.homes.isEmpty else {
            return "Apple TV 的 Apple ID 沒有讀到任何家庭；請確認它與 iPhone 使用相同的家庭帳號。"
        }

        let accessoryCount = manager.homes.reduce(0) { $0 + $1.accessories.count }
        let cameraCount = manager.homes
            .flatMap(\.accessories)
            .reduce(0) { $0 + ($1.cameraProfiles?.count ?? 0) }
        return "已讀到 \(manager.homes.count) 個家庭、\(accessoryCount) 個配件，但 HomeKit 沒有提供攝影機串流設定檔（\(cameraCount) 個）。"
    }

    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        _ = currentChannels()
    }

    private func currentChannels() -> [NewsChannel] {
        var result: [NewsChannel] = []
        var updatedSessions: [String: HomeKitCameraSession] = [:]

        for home in manager.homes {
            for accessory in home.accessories {
                for (index, profile) in (accessory.cameraProfiles ?? []).enumerated() {
                    guard let control = profile.streamControl else { continue }
                    let id = "homekit:\(accessory.uniqueIdentifier.uuidString):\(index)"
                    let room = accessory.room?.name ?? home.name
                    let displayName = room == accessory.name
                        ? accessory.name
                        : "\(accessory.name) · \(room)"
                    guard let placeholderURL = URL(string: "homekit://camera/\(accessory.uniqueIdentifier.uuidString)/\(index)") else { continue }

                    updatedSessions[id] = sessions[id] ?? HomeKitCameraSession(
                        control: control,
                        snapshotControl: profile.snapshotControl
                    )
                    result.append(NewsChannel(
                        id: id,
                        name: displayName,
                        url: placeholderURL,
                        logoURL: nil,
                        country: "HOME",
                        category: .homekit
                    ))
                }
            }
        }

        sessions = updatedSessions
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
