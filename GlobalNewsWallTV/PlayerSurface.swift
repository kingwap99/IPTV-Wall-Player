import AVFoundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
extension Notification.Name {
    static let newsWallResumePlayback = Notification.Name("NewsWallResumePlayback")
}

private final class PlayerLayerAttachment {
    weak var containerLayer: CALayer?
    let priority: Int

    init(containerLayer: CALayer, priority: Int) {
        self.containerLayer = containerLayer
        self.priority = priority
    }
}

final class PlayerSession {
    let key: String
    let url: URL
    let player: AVPlayer
    let videoLayer: AVPlayerLayer
    var statusObservation: NSKeyValueObservation?
    var failureObserver: NSObjectProtocol?
    private var layerAttachments: [UUID: PlayerLayerAttachment] = [:]
    private var activeLayerOwnerID: UUID?
    private var failureHandlers: [UUID: () -> Void] = [:]
    private var fadeTimer: Timer?
    private var mutedTarget: Bool?
    private var volumeTarget: Float?
    private var retryTimer: Timer?
    private var retryCount = 0
    private let isGo2RTCStream: Bool

    init(channel: NewsChannel, key: String) {
        self.key = key
        url = channel.url
        isGo2RTCStream = channel.url.port == 1984

        let item = AVPlayerItem(url: channel.url)
        item.preferredForwardBufferDuration = 6
        let createdPlayer = AVPlayer(playerItem: item)
        player = createdPlayer
        videoLayer = AVPlayerLayer(player: createdPlayer)
        videoLayer.videoGravity = .resizeAspectFill
       player.isMuted = true
       player.volume = 0
        player.automaticallyWaitsToMinimizeStalling = true

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            self?.notifyFailure()
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.notifyFailure()
        }
    }

    func register(ownerID: UUID, onFailure: @escaping () -> Void) {
        failureHandlers[ownerID] = onFailure
    }

    func unregister(ownerID: UUID) {
        failureHandlers.removeValue(forKey: ownerID)
    }

    var hasOwners: Bool {
        !failureHandlers.isEmpty
    }

    func attach(to containerLayer: CALayer, ownerID: UUID, priority: Int) {
        layerAttachments[ownerID] = PlayerLayerAttachment(
            containerLayer: containerLayer,
            priority: priority
        )
        activatePreferredLayer()
    }

    func detach(ownerID: UUID) {
        layerAttachments.removeValue(forKey: ownerID)
        guard activeLayerOwnerID == ownerID else { return }
        videoLayer.removeFromSuperlayer()
        activeLayerOwnerID = nil
        activatePreferredLayer()
    }

    func updatePlayback(muted: Bool, volume: Float, paused: Bool) {
        player.currentItem?.preferredForwardBufferDuration = muted ? 6 : 12
        applyAudio(muted: muted, volume: volume, animated: true)
        if paused {
            player.pause()
        } else {
            player.play()
        }
    }

    func fadeOutForHandoff() {
        applyAudio(muted: true, volume: 0, animated: true)
    }

    func resume() {
        player.play()
    }

    private func notifyFailure() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.isGo2RTCStream, self.retryCount < 3 {
                self.retryCount += 1
                self.scheduleGo2RTCRetry()
            }
            let handlers = Array(self.failureHandlers.values)
            for handler in handlers {
                handler()
            }
        }
    }

    private func scheduleGo2RTCRetry() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            print("GO2RTC_PLAYER_RETRY attempt=\(self.retryCount) url=\(self.url.absoluteString)")
            self.reloadCurrentItem()
        }
    }

    private func reloadCurrentItem() {
        statusObservation?.invalidate()
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 6
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            self?.notifyFailure()
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.notifyFailure()
        }
        player.replaceCurrentItem(with: item)
        player.play()
    }

   func stop() {
       retryTimer?.invalidate()
       retryTimer = nil
       fadeTimer?.invalidate()
        fadeTimer = nil
        mutedTarget = nil
        volumeTarget = nil
        statusObservation?.invalidate()
        statusObservation = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        layerAttachments.removeAll()
        activeLayerOwnerID = nil
        videoLayer.removeFromSuperlayer()
        videoLayer.player = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        failureHandlers.removeAll()
    }

    deinit {
        stop()
    }


    private func activatePreferredLayer() {
        layerAttachments = layerAttachments.filter { $0.value.containerLayer != nil }
        guard let highestPriority = layerAttachments.values.map(\.priority).max() else {
            videoLayer.removeFromSuperlayer()
            activeLayerOwnerID = nil
            return
        }

        let selected: (ownerID: UUID, attachment: PlayerLayerAttachment)?
        if let activeLayerOwnerID,
           let activeAttachment = layerAttachments[activeLayerOwnerID],
           activeAttachment.priority == highestPriority,
           activeAttachment.containerLayer != nil {
            selected = (activeLayerOwnerID, activeAttachment)
        } else if let candidate = layerAttachments.first(where: { $0.value.priority == highestPriority }) {
            selected = (candidate.key, candidate.value)
        } else {
            selected = nil
        }

        guard let selected, let containerLayer = selected.attachment.containerLayer else { return }
        guard activeLayerOwnerID != selected.ownerID || videoLayer.superlayer !== containerLayer else {
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.removeFromSuperlayer()
        videoLayer.frame = containerLayer.bounds
        containerLayer.addSublayer(videoLayer)
        CATransaction.commit()
        activeLayerOwnerID = selected.ownerID
    }

    private func applyAudio(muted: Bool, volume: Float, animated: Bool) {
        let clampedVolume = min(1, max(0, volume))
        if mutedTarget == muted,
           let volumeTarget,
           abs(volumeTarget - clampedVolume) < 0.001 {
            return
        }
        mutedTarget = muted
        volumeTarget = clampedVolume
        fadeTimer?.invalidate()
        fadeTimer = nil

        if !animated {
            player.isMuted = muted
            player.volume = muted ? 0 : clampedVolume
            return
        }

        let startVolume = player.volume
        let endVolume: Float = muted ? 0 : clampedVolume
        if abs(startVolume - endVolume) < 0.001 {
            player.volume = endVolume
            player.isMuted = muted
            return
        }

        let duration: TimeInterval = muted ? 0.45 : 0.65
        let interval: TimeInterval = 0.025
        let steps = max(1, Int(duration / interval))
        var currentStep = 0

        if !muted {
            player.isMuted = false
            if startVolume == 0 {
                player.volume = 0
            }
        }

        fadeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self, weak player] timer in
            guard let self, let player else {
                timer.invalidate()
                return
            }

            currentStep += 1
            let rawProgress = min(1, Float(currentStep) / Float(steps))
            let easedProgress = rawProgress * rawProgress * (3 - 2 * rawProgress)
            player.volume = startVolume + (endVolume - startVolume) * easedProgress

            if rawProgress >= 1 {
                timer.invalidate()
                self.fadeTimer = nil
                player.volume = endVolume
                player.isMuted = muted
            }
        }
    }
}

final class PlayerPool {
    static let shared = PlayerPool()

    private var sessions: [String: PlayerSession] = [:]
    private var evictionTasks: [String: DispatchWorkItem] = [:]
    private var releasedSessionRetentionUntil = Date.distantPast

    private init() {}

    func key(for channel: NewsChannel) -> String {
        "\(channel.id)|\(channel.url.absoluteString)"
    }

    func retainReleasedSessions(for duration: TimeInterval) {
        releasedSessionRetentionUntil = max(
            releasedSessionRetentionUntil,
            Date().addingTimeInterval(duration)
        )
    }

    func acquire(
        channel: NewsChannel,
        ownerID: UUID,
        onFailure: @escaping () -> Void
    ) -> PlayerSession {
        let key = key(for: channel)
        evictionTasks.removeValue(forKey: key)?.cancel()

        let session: PlayerSession
        if let existing = sessions[key] {
            session = existing
        } else {
            session = PlayerSession(channel: channel, key: key)
            sessions[key] = session
        }
        session.register(ownerID: ownerID, onFailure: onFailure)
        return session
    }

    func release(_ session: PlayerSession, ownerID: UUID) {
        session.unregister(ownerID: ownerID)
        guard !session.hasOwners else { return }

        session.fadeOutForHandoff()
        let key = session.key
        evictionTasks.removeValue(forKey: key)?.cancel()
        let task = DispatchWorkItem { [weak self, weak session] in
            guard let self,
                  let session,
                  self.sessions[key] === session,
                  !session.hasOwners else { return }
            self.sessions.removeValue(forKey: key)
            self.evictionTasks.removeValue(forKey: key)
            session.stop()
        }
        evictionTasks[key] = task
        let retentionDelay = max(1.5, releasedSessionRetentionUntil.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + retentionDelay, execute: task)
    }
}

final class PlayerCoordinator {
    let ownerID = UUID()
    var session: PlayerSession?
    weak var playerLayer: AVPlayerLayer?
    var readinessObservation: NSKeyValueObservation?
    var readinessHandler: ((Bool) -> Void)?
    var resumeObservers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        resumeObservers.append(
            center.addObserver(forName: .newsWallResumePlayback, object: nil, queue: .main) { [weak self] _ in
                self?.resume()
            }
        )
        #if !os(macOS)
        resumeObservers.append(
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.resume()
            }
        )
        #endif
    }

    func resume() {
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        session?.resume()
    }

    func observeReadiness(
        of layer: AVPlayerLayer,
        onChange: @escaping (Bool) -> Void
    ) {
        readinessHandler = onChange
        guard playerLayer !== layer || readinessObservation == nil else {
            onChange(layer.isReadyForDisplay)
            return
        }

        readinessObservation?.invalidate()
        playerLayer = layer
        readinessObservation = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            DispatchQueue.main.async { [weak self] in
                self?.readinessHandler?(layer.isReadyForDisplay)
            }
        }
    }

    func releaseSession() {
        guard let session else { return }
        readinessObservation?.invalidate()
        readinessObservation = nil
        readinessHandler?(false)
        readinessHandler = nil
        session.detach(ownerID: ownerID)
        PlayerPool.shared.release(session, ownerID: ownerID)
        self.session = nil
        playerLayer = nil
    }

    deinit {
        for observer in resumeObservers { NotificationCenter.default.removeObserver(observer) }
        releaseSession()
    }
}

private func updatePlayer(
    channel: NewsChannel,
    muted: Bool,
    volume: Float,
    paused: Bool,
    isPrimary: Bool,
    containerLayer: CALayer,
    coordinator: PlayerCoordinator,
    onReadinessChange: @escaping (Bool) -> Void,
    onFailure: @escaping () -> Void
) {
    let pool = PlayerPool.shared
    let desiredKey = pool.key(for: channel)
    if coordinator.session?.key != desiredKey {
        coordinator.releaseSession()
        coordinator.session = pool.acquire(
            channel: channel,
            ownerID: coordinator.ownerID,
            onFailure: onFailure
        )
    } else {
        coordinator.session?.register(ownerID: coordinator.ownerID, onFailure: onFailure)
    }

    guard let session = coordinator.session else { return }
    coordinator.observeReadiness(of: session.videoLayer, onChange: onReadinessChange)
    session.attach(
        to: containerLayer,
        ownerID: coordinator.ownerID,
        priority: isPrimary ? 1 : 0
    )
    session.updatePlayback(muted: muted, volume: volume, paused: paused)
}

struct PlayerSurface: View {
    @State private var isReadyForDisplay = false

    let channel: NewsChannel
    let muted: Bool
    var volume: Float = 1
    let paused: Bool
    var isPrimary = false
    let onFailure: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                PlatformPlayerSurface(
                    channel: channel,
                    muted: muted,
                    volume: volume,
                    paused: paused,
                    isPrimary: isPrimary,
                    onReadinessChange: updateReadiness,
                    onFailure: onFailure
                )

                if !isReadyForDisplay {
                    AnimatedIPTVWallLoadingLogo(
                        size: min(72, max(28, min(proxy.size.width, proxy.size.height) * 0.2))
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func updateReadiness(_ ready: Bool) {
        guard ready != isReadyForDisplay else { return }
        withAnimation(.easeOut(duration: ready ? 0.22 : 0.12)) {
            isReadyForDisplay = ready
        }
    }
}

private struct AnimatedIPTVWallLoadingLogo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let size: CGFloat

    var body: some View {
        Group {
            if reduceMotion {
                logo(phase: nil)
            } else {
                PhaseAnimator([0, 1, 2, 3]) { phase in
                    logo(phase: phase)
                } animation: { _ in
                    .easeInOut(duration: 0.3)
                }
            }
        }
        .frame(width: size, height: size)
        .shadow(color: Color.black.opacity(0.5), radius: size * 0.16, y: size * 0.05)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func logo(phase: Int?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.04, green: 0.58, blue: 0.96),
                            Color(red: 0.25, green: 0.32, blue: 0.78)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(spacing: size * 0.055) {
                HStack(spacing: size * 0.055) {
                    logoCell(index: 0, phase: phase)
                    logoCell(index: 1, phase: phase)
                }
                HStack(spacing: size * 0.055) {
                    logoCell(index: 3, phase: phase)
                    logoCell(index: 2, phase: phase)
                }
            }
        }
    }

    private func logoCell(index: Int, phase: Int?) -> some View {
        let isActive = phase == nil || phase == index
        return RoundedRectangle(cornerRadius: size * 0.045)
            .fill(Color.white.opacity(isActive ? 0.98 : 0.42))
            .frame(width: size * 0.19, height: size * 0.19)
            .scaleEffect(isActive ? 1.08 : 0.9)
    }
}

#if os(macOS)
final class PlayerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let rootLayer = CALayer()
        rootLayer.backgroundColor = NSColor.black.cgColor
        rootLayer.masksToBounds = true
        layer = rootLayer
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        resizeVideoLayer()
    }

    var containerLayer: CALayer { layer! }

    private func resizeVideoLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerLayer.sublayers?.forEach { $0.frame = containerLayer.bounds }
        CATransaction.commit()
    }
}

private struct PlatformPlayerSurface: NSViewRepresentable {
    let channel: NewsChannel
    let muted: Bool
    var volume: Float = 1
    let paused: Bool
    let isPrimary: Bool
    let onReadinessChange: (Bool) -> Void
    let onFailure: () -> Void

    func makeCoordinator() -> PlayerCoordinator { PlayerCoordinator() }

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
        updatePlayer(channel: channel, muted: muted, volume: volume, paused: paused, isPrimary: isPrimary, containerLayer: view.containerLayer, coordinator: context.coordinator, onReadinessChange: onReadinessChange, onFailure: onFailure)
        return view
    }

    func updateNSView(_ view: PlayerView, context: Context) {
        updatePlayer(channel: channel, muted: muted, volume: volume, paused: paused, isPrimary: isPrimary, containerLayer: view.containerLayer, coordinator: context.coordinator, onReadinessChange: onReadinessChange, onFailure: onFailure)
    }

    static func dismantleNSView(_ view: PlayerView, coordinator: PlayerCoordinator) {
        coordinator.releaseSession()
    }
}
#else
final class PlayerView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        layer.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        resizeVideoLayer()
    }

    var containerLayer: CALayer { layer }

    private func resizeVideoLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerLayer.sublayers?.forEach { $0.frame = containerLayer.bounds }
        CATransaction.commit()
    }
}

private struct PlatformPlayerSurface: UIViewRepresentable {
    let channel: NewsChannel
    let muted: Bool
    var volume: Float = 1
    let paused: Bool
    let isPrimary: Bool
    let onReadinessChange: (Bool) -> Void
    let onFailure: () -> Void

    func makeCoordinator() -> PlayerCoordinator { PlayerCoordinator() }

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        updatePlayer(channel: channel, muted: muted, volume: volume, paused: paused, isPrimary: isPrimary, containerLayer: view.containerLayer, coordinator: context.coordinator, onReadinessChange: onReadinessChange, onFailure: onFailure)
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        updatePlayer(channel: channel, muted: muted, volume: volume, paused: paused, isPrimary: isPrimary, containerLayer: view.containerLayer, coordinator: context.coordinator, onReadinessChange: onReadinessChange, onFailure: onFailure)
    }

    static func dismantleUIView(_ view: PlayerView, coordinator: PlayerCoordinator) {
        coordinator.releaseSession()
    }
}
#endif
