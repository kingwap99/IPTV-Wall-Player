import Combine
import SwiftUI
#if os(tvOS)
import TVServices
#endif
#if os(macOS)
import AppKit
import CoreAudio
import Darwin
import UniformTypeIdentifiers

@MainActor
private final class MacActivationClickGuard: NSObject {
    static let shared = MacActivationClickGuard()

    private var suppressedWindowNumber: Int?
    private var suppressAnyWindow = false
    private var recentActivationWindowNumber: Int?
    private var suppressRecentAnyWindow = false
    private var recentActivationExpiresAt = Date.distantPast
    private var mouseUpMonitor: Any?

    override private init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self, self.hasPendingActivationClick else { return event }
            DispatchQueue.main.async { [weak self] in
                self?.clearPendingActivationClick()
            }
            return event
        }
    }

    func consumeActivationClick(in window: NSWindow?) -> Bool {
        let pendingMatches = hasPendingActivationClick
            && (suppressAnyWindow || window?.windowNumber == suppressedWindowNumber)
        let recentMatches = Date() <= recentActivationExpiresAt
            && (suppressRecentAnyWindow || window?.windowNumber == recentActivationWindowNumber)
        guard pendingMatches || recentMatches else { return false }
        clearPendingActivationClick()
        clearRecentActivationClick()
        return true
    }

    @objc private func applicationDidBecomeActive() {
        let event = NSApp.currentEvent
        let activatedByLeftClick = event?.type == .leftMouseDown || (NSEvent.pressedMouseButtons & 1) != 0
        guard activatedByLeftClick else {
            clearPendingActivationClick()
            clearRecentActivationClick()
            return
        }

        if let windowNumber = event?.windowNumber, windowNumber > 0 {
            suppressedWindowNumber = windowNumber
            suppressAnyWindow = false
            recentActivationWindowNumber = windowNumber
            suppressRecentAnyWindow = false
        } else {
            suppressedWindowNumber = nil
            suppressAnyWindow = true
            recentActivationWindowNumber = nil
            suppressRecentAnyWindow = true
        }
        recentActivationExpiresAt = Date().addingTimeInterval(0.6)
    }

    private var hasPendingActivationClick: Bool {
        suppressAnyWindow || suppressedWindowNumber != nil
    }

    private func clearPendingActivationClick() {
        suppressedWindowNumber = nil
        suppressAnyWindow = false
    }

    private func clearRecentActivationClick() {
        recentActivationWindowNumber = nil
        suppressRecentAnyWindow = false
        recentActivationExpiresAt = .distantPast
    }
}
#endif

private func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

private func platformM3UImportHint() -> String {
    #if os(tvOS)
    localized("可從手機複製 M3U 網址，再使用 Apple TV 遙控器鍵盤貼上。")
    #elseif os(iOS)
    localized("貼上你有權使用的 M3U 播放清單網址。")
    #else
    localized("可直接貼上 M3U 網址，或從 iptv-org 探索公開頻道。")
    #endif
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = ChannelStore()
    #if os(macOS)
    private let macActivationClickGuard = MacActivationClickGuard.shared
    #endif
    @FocusState private var mainFocus: MainFocus?
    @State private var controlsVisible = true
    @State private var heroBrandOverlayVisible = false
    @State private var lastInteraction = Date()
    @State private var pointerInsideWindow = false
    @State private var allPlaybackPaused = false
    @AppStorage("autoAudioDuckingEnabled") private var autoAudioDuckingEnabled = true
    @AppStorage("autoAudioDuckingDefaultEnabledV2") private var autoAudioDuckingDefaultEnabledV2 = false
    @AppStorage("heroPlaybackVolume") private var heroPlaybackVolume = 0.7
    @AppStorage("modeBeforeFullscreen.v1") private var modeBeforeFullscreenRawValue = WallMode.five.rawValue
    @AppStorage("pageBeforeFullscreen.v1") private var pageBeforeFullscreen = 0
    @AppStorage("totalPlaybackSeconds.v1") private var persistedPlaybackSeconds = 0.0
    @State private var pendingPlaybackSeconds = 0.0
    @State private var lastPlaybackAccountingAt = Date()
    @State private var lastPlaybackPersistenceAt = Date()
    @State private var volumeSettingsPresented = false
    @State private var autoMutedByOtherAudio = false
    @State private var externalAudioActiveSince: Date?
    @State private var externalAudioInactiveSince: Date?
    @State private var externalAudioActiveSignature = ""
    @State private var pendingUnfavorite: NewsChannel?
    @State private var pendingDelete: NewsChannel?
    @State private var pendingDeleteIndex: Int?
    @State private var miniActionChannel: NewsChannel?
    @State private var heroLongPressTriggered = false
    @State private var quickActionReturnFocusChannelID: String?
    @State private var reorderingChannelID: String?
    @State private var reorderSessionActive = false
    @State private var reorderCategory: ChannelCategory?
    @State private var reorderSnapshot: [String] = []
    @State private var m3uManagerPresented = false
    @State private var channelExplorerPresented = false
    @State private var heroChannelActionsPresented = false
    @State private var channelInfoPresented: NewsChannel?
    @State private var onboardingMessage: String?
    private let idleCheck = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    private let remoteSyncCheck = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    #if os(macOS)
    private let externalAudioCheck = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    #endif

    var body: some View {
        let root = GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()
                // Keep the first-use surface visible until local and iCloud loading has
                // completed. CloudKit can populate `featured` before `load()` returns.
                if store.isLoading {
                    emptyState
                } else if let featured = store.featured {
                    wall(
                        featured: featured,
                        size: proxy.size,
                        safeAreaInsets: proxy.safeAreaInsets
                    )
                } else {
                    emptyState
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            #if os(tvOS)
            .ignoresSafeArea()
            #endif
        }
        #if os(tvOS)
        .ignoresSafeArea()
        #endif

        let lifecycle = root
        .platformPointerActivity(
            onActive: recordPointerActivity,
            onEnded: recordPointerExit
        )
        .task {
            #if os(macOS)
            if !autoAudioDuckingDefaultEnabledV2 {
                autoAudioDuckingEnabled = true
                autoAudioDuckingDefaultEnabledV2 = true
            }
            #endif
            await store.load()
            if ProcessInfo.processInfo.arguments.contains("--enable-cloud-sync-for-ui-testing") {
                store.setCloudLibrarySyncEnabled(true)
                await store.syncCloudLibraryIfNeeded(force: true)
            }
            #if !os(macOS)
            mainFocus = store.featured == nil ? .m3uManager : .hero
            #else
            mainFocus = store.featured == nil ? .starterChannels : .hero
            #endif
            if ProcessInfo.processInfo.arguments.contains("--force-hero-focus-for-ui-testing") {
                try? await Task.sleep(for: .milliseconds(500))
                mainFocus = .hero
            }
            if ProcessInfo.processInfo.arguments.contains("--force-unfavorite-focus-for-ui-testing") {
                try? await Task.sleep(for: .milliseconds(500))
                mainFocus = .favorite
            }
            if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--force-mini-focus-index-for-ui-testing=") }),
               let index = Int(argument.split(separator: "=").last ?? ""),
               store.pageChannels.indices.contains(index) {
                try? await Task.sleep(for: .milliseconds(500))
                mainFocus = .miniCenter(store.pageChannels[index].id)
            }
            if ProcessInfo.processInfo.arguments.contains("--open-m3u-manager-for-ui-testing") {
                try? await Task.sleep(for: .milliseconds(500))
                m3uManagerPresented = true
            }
            #if os(macOS)
            if ProcessInfo.processInfo.arguments.contains("--open-channel-explorer-for-ui-testing") {
                try? await Task.sleep(for: .milliseconds(500))
                channelExplorerPresented = true
            }
            #endif
            if ProcessInfo.processInfo.arguments.contains("--open-hero-actions-for-ui-testing") {
                try? await Task.sleep(for: .milliseconds(500))
                heroChannelActionsPresented = true
            }
            if ProcessInfo.processInfo.arguments.contains("--print-sync-diagnostics") {
                let importedChannelCount = store.importedPlaylists.reduce(0) { $0 + $1.channelCount }
                #if os(tvOS)
                let multiUserPreferences = TVUserManager().shouldStorePreferencesForCurrentUser
                #else
                let multiUserPreferences = false
                #endif
                print(
                    "IPTVWALL_SYNC_DIAGNOSTICS " +
                    "playlists=\(store.importedPlaylists.count) " +
                    "channels=\(importedChannelCount) " +
                    "favorites=\(store.favorites.count) " +
                    "deleted=\(store.deletedChannelIDs.count) " +
                    "cloudEnabled=\(store.isCloudLibrarySyncEnabled) " +
                    "cloudSynced=\(store.cloudLibraryLastSyncedAt != nil) " +
                    "cloudError=\(store.cloudLibraryError ?? "none") " +
                    "multiUserPreferences=\(multiUserPreferences)"
                )
            }
            recordActivity()
            lastPlaybackAccountingAt = Date()
            lastPlaybackPersistenceAt = Date()
        }
        .task(id: store.featured?.id) {
            guard store.featured != nil else {
                heroBrandOverlayVisible = false
                return
            }

            heroBrandOverlayVisible = true
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.28)) {
                heroBrandOverlayVisible = false
            }
        }
        .onReceive(idleCheck) { now in
            accountPlaybackTime(until: now)
            #if os(tvOS)
            if !reorderSessionActive,
               controlsVisible && now.timeIntervalSince(lastInteraction) >= 10 {
                mainFocus = .hero
                withAnimation(.easeOut(duration: 0.28)) { controlsVisible = false }
            }
            #elseif os(macOS)
            let timeout: TimeInterval = pointerInsideWindow ? 5 : 3
            if !reorderSessionActive,
               controlsVisible && now.timeIntervalSince(lastInteraction) >= timeout {
                withAnimation(.easeOut(duration: 0.28)) { controlsVisible = false }
            }
            #elseif os(iOS)
            if !reorderSessionActive,
               controlsVisible && now.timeIntervalSince(lastInteraction) >= 5 {
                mainFocus = .hero
                withAnimation(.easeOut(duration: 0.28)) { controlsVisible = false }
            }
            #endif
        }
        .onChange(of: scenePhase) { _, newPhase in
            accountPlaybackTime(until: Date(), persist: newPhase != .active)
            lastPlaybackAccountingAt = Date()
        }
        .onChange(of: allPlaybackPaused) { _, _ in
            accountPlaybackTime(until: Date(), persist: true)
            lastPlaybackAccountingAt = Date()
        }
        .onReceive(remoteSyncCheck) { _ in
            Task {
                await store.syncRemotePlaylistIfNeeded(force: false)
                await store.syncCloudLibraryIfNeeded(force: false)
            }
        }
        #if os(macOS)
        .onReceive(externalAudioCheck) { now in
            updateAutoMuteState(now: now)
        }
        #endif

        let commands = lifecycle
        .platformRemoteCommands(
            onMove: handleMoveCommand,
            onPlayPause: {
                recordActivity()
                resumePlayback()
            },
            onExit: handleExitCommand
        )

        let alerts = commands
        .alert("從我的最愛移除？", isPresented: unfavoriteConfirmationPresented, presenting: pendingUnfavorite) { channel in
            Button("保留", role: .cancel) {}
            Button("移除", role: .destructive) {
                store.toggleFavorite(channel)
                pendingUnfavorite = nil
                recordActivity()
            }
        } message: { channel in
            Text("確定要將「\(channel.name)」從我的最愛移除嗎？")
        }
        .alert("刪除小頻道？", isPresented: deleteConfirmationPresented, presenting: pendingDelete) { channel in
            Button("保留", role: .cancel) {}
            Button("刪除", role: .destructive) {
                let focusIndex = pendingDeleteIndex
                store.deleteChannel(channel)
                pendingDelete = nil
                pendingDeleteIndex = nil
                restoreMiniFocusAfterDelete(previousIndex: focusIndex)
                recordActivity()
            }
        } message: { channel in
            Text("確定要將「\(channel.name)」從播放牆隱藏嗎？此操作會同步至你的其他裝置。")
        }

        #if os(iOS)
        let dialogs = alerts.sheet(
            isPresented: $heroChannelActionsPresented,
            onDismiss: restoreMainFocus
        ) {
            if let channel = store.featured {
                heroActionsSheet(channel)
            }
        }
        #else
        let heroDialogs = alerts.confirmationDialog(
            store.featured.map { "\(localized("頻道選項")) · \($0.name)" } ?? localized("頻道選項"),
            isPresented: $heroChannelActionsPresented,
            titleVisibility: .visible,
            presenting: store.featured
        ) { channel in
            heroChannelActionButtons(channel)
        }
        #if os(tvOS)
        let dialogs = heroDialogs.confirmationDialog(
            miniActionChannel.map { "頻道選項 · \($0.name)" } ?? "頻道選項",
            isPresented: miniActionMenuPresented,
            titleVisibility: .visible,
            presenting: miniActionChannel
        ) { channel in
            miniChannelActionButtons(channel)
        }
        #else
        let dialogs = heroDialogs
        #endif
        #endif

        return dialogs
        .sheet(isPresented: $m3uManagerPresented, onDismiss: restoreMainFocus) {
            #if !os(macOS)
            M3UManagerView(store: store)
            #else
            M3UManagerView(store: store) {
                m3uManagerPresented = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    channelExplorerPresented = true
                }
            }
            #endif
        }
        #if os(macOS)
        .sheet(isPresented: $channelExplorerPresented, onDismiss: restoreMainFocus) {
            IPTVOrgExplorerView(store: store)
        }
        #endif
        .sheet(item: $channelInfoPresented, onDismiss: restoreMainFocus) { channel in
            ChannelInfoView(channel: channel)
        }
        #if os(macOS)
        .sheet(isPresented: $volumeSettingsPresented, onDismiss: restoreMainFocus) {
            HeroVolumeSettingsView(volume: $heroPlaybackVolume)
        }
        #endif
    }

    @ViewBuilder
    private func wall(featured: NewsChannel, size: CGSize, safeAreaInsets: EdgeInsets) -> some View {
        if store.mode == .fullscreen {
            hero(featured, safeAreaInsets: safeAreaInsets)
                .frame(width: size.width, height: size.height)
                #if os(iOS)
                .simultaneousGesture(iosPageSwipeGesture)
                #endif
        } else {
            let count = store.mode.gridDimension
            let cellWidth = size.width / CGFloat(count)
            let cellHeight = size.height / CGFloat(count)
            ZStack(alignment: .topLeading) {
                ForEach(Array(store.pageChannels.enumerated()), id: \.element.id) { index, channel in
                    let cell = perimeterCells(count: count)[index]
                    MiniChannelView(
                        channel: channel,
                        index: store.displayIndex(of: channel),
                        isFavorite: store.isFavorite(channel),
                        isFeatured: channel.id == featured.id,
                        controlsVisible: controlsVisible,
                        allPlaybackPaused: allPlaybackPaused,
                        totalPlaybackSeconds: totalPlaybackSeconds,
                        autoAudioDuckingEnabled: autoAudioDuckingEnabled,
                        autoMutedByOtherAudio: autoMutedByOtherAudio,
                        isReorderMode: reorderSessionActive,
                        isBeingReordered: reorderingChannelID == channel.id,
                        focus: $mainFocus,
                        onPrimaryAction: { handleMiniPrimaryAction(channel) },
                        onMore: { showMiniActions(channel) },
                        onFavorite: { requestFavoriteToggle(channel) },
                        onInfo: { showChannelInfo(channel) },
                        onBeginReorder: { beginChannelReordering(channel) },
                        onFinishReorder: finishChannelReordering,
                        onCancelReorder: cancelChannelReordering,
                        onDelete: { requestChannelDelete(channel) },
                        onDropReorder: { sourceID in
                            moveReorderingChannel(sourceID: sourceID, to: channel)
                        },
                        onActivity: recordActivity,
                        onFailure: {
                            if channel.category != .go2rtc && !Self.isLocalIPTV(channel) {
                                store.markUnavailable(channel)
                            }
                        }
                    )
                    .frame(width: cellWidth, height: cellHeight)
                    .platformFocusSection()
                    .position(
                        x: CGFloat(cell.column) * cellWidth + cellWidth / 2,
                        y: CGFloat(cell.row) * cellHeight + cellHeight / 2
                    )
                }

                let heroSpan = count - 2
                let heroWidth = cellWidth * CGFloat(heroSpan)
                let heroHeight = cellHeight * CGFloat(heroSpan)
                hero(featured)
                    .frame(
                        width: heroWidth,
                        height: heroHeight
                    )
                    .position(x: size.width / 2, y: size.height / 2)

                if reorderSessionActive {
                    HStack(spacing: 12) {
                        #if os(iOS) || os(macOS)
                        Label(
                            localized("調整順序：拖曳任意頻道交換位置，完成後點選「完成」"),
                            systemImage: "hand.draw"
                        )
                        #else
                        Label(
                            localized("調整順序：中央鍵拿起頻道，方向鍵移動後放下；長按頻道完成或取消"),
                            systemImage: "arrow.up.and.down.and.arrow.left.and.right"
                        )
                        #endif
                        #if os(macOS) || os(iOS)
                        Button(localized("取消")) {
                            cancelChannelReordering()
                        }
                        .keyboardShortcut(.cancelAction)
                        Button(localized("完成")) {
                            finishChannelReordering()
                        }
                        .keyboardShortcut(.defaultAction)
                        #endif
                    }
                    .font(.caption.bold())
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .foregroundStyle(.black)
                    .background(Color.yellow, in: Capsule())
                    .shadow(color: .black.opacity(0.55), radius: 10)
                    .padding(.vertical, 18)
                    .frame(
                        width: size.width,
                        height: size.height,
                        alignment: reorderToolbarAtBottom(count: count) ? .bottom : .top
                    )
                    .animation(
                        .easeInOut(duration: 0.2),
                        value: reorderToolbarAtBottom(count: count)
                    )
                    .zIndex(100)
                }
            }
            #if os(iOS)
            .simultaneousGesture(iosPageSwipeGesture)
            #endif
        }
    }

    private func hero(
        _ channel: NewsChannel,
        safeAreaInsets: EdgeInsets = EdgeInsets()
    ) -> some View {
        ZStack(alignment: .bottomLeading) {
            PlayerSurface(
                channel: channel,
                muted: heroMuted,
                volume: Float(heroPlaybackVolume),
                paused: allPlaybackPaused,
                isPrimary: true
            ) {
                if channel.category != .go2rtc && !Self.isLocalIPTV(channel) {
                    store.markUnavailable(channel)
                }
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                #if os(iOS)
                .gesture(iosHeroTapGesture)
                .onLongPressGesture(minimumDuration: 0.55, maximumDistance: 28) {
                    heroLongPressTriggered = true
                    showHeroChannelActions()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        heroLongPressTriggered = false
                    }
                }
                #elseif os(macOS)
                .gesture(macHeroTapGesture)
                .contextMenu {
                    heroContextMenuItems(channel)
                }
                #endif

            #if os(tvOS)
            Color.clear
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focusable()
                .focusEffectDisabled()
                .focused($mainFocus, equals: .hero)
                .onTapGesture {
                    if heroLongPressTriggered {
                        heroLongPressTriggered = false
                        return
                    }
                    toggleHeroFullscreen()
                }
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.65)
                        .onEnded { _ in
                            heroLongPressTriggered = true
                            showHeroChannelActions()
                        }
                )
            #endif

            LinearGradient(colors: [.clear, .black.opacity(0.88)], startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)
                .opacity(controlsVisible ? 1 : 0)

            VStack(alignment: .leading, spacing: 8) {
                if store.mode == .fullscreen {
                    Label {
                        Text(allPlaybackPaused ? localized("已暫停") : "LIVE")
                    } icon: {
                        Image(systemName: allPlaybackPaused ? "pause.fill" : "dot.radiowaves.left.and.right")
                    }
                    .font(.caption2.bold())
                    .foregroundStyle(allPlaybackPaused ? Color.yellow : (heroMuted ? Color.orange : Color.red))
                    Text("\(flag(channel.country)) \(countryName(channel.country))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(channel.name)
                        .font(.headline.bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(fullscreenOverlayPadding(heroInfoPadding, safeAreaInsets: safeAreaInsets))
            .opacity(controlsVisible ? 1 : 0)
            .allowsHitTesting(controlsVisible)

            if heroBrandVisible {
                HStack(spacing: heroBrandSpacing) {
                    IPTVWallLogoMark(size: heroBrandMarkSize, style: .brandBlue)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("IPTV WALL")
                                .font(heroBrandTitleFont)
                                .tracking(1.2)
                            Text("Player")
                                .font(heroBrandSubtitleFont)
                                .foregroundStyle(Color.white.opacity(0.82))
                        }
                        Text(localized("一覽無遺千萬頻"))
                            .font(heroBrandSubtitleFont)
                            .foregroundStyle(Color.white.opacity(0.72))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.45), radius: 8, y: 2)
                .padding(heroBrandPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .opacity(heroBrandOverlayVisible ? 1 : 0)
                .allowsHitTesting(false)
            }

        }
        .background(Color.black)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .platformHeroSafeArea()
        .clipShape(RoundedRectangle(cornerRadius: store.mode == .fullscreen ? 0 : 20))
        .overlay {
            RoundedRectangle(cornerRadius: store.mode == .fullscreen ? 0 : 20)
                .strokeBorder(
                    controlsVisible && heroHasFocus
                        ? Color.yellow
                        : store.mode == .fullscreen ? Color.clear : Color.white.opacity(0.18),
                    lineWidth: controlsVisible && heroHasFocus ? 6 : 2
                )
        }
        .accessibilityAction(named: Text(localized("切換全螢幕"))) {
            toggleHeroFullscreen()
        }
        .accessibilityAction(named: Text(localized("顯示頻道選項"))) {
            showHeroChannelActions()
        }
    }

    #if os(iOS)
    private var iosHeroTapGesture: some Gesture {
        TapGesture(count: 2)
            .exclusively(before: TapGesture(count: 1))
            .onEnded { value in
                switch value {
                case .first:
                    handleIOSHeroDoubleTap()
                case .second:
                    handleIOSHeroSingleTap()
                }
            }
    }

    private func handleIOSHeroSingleTap() {
        if heroLongPressTriggered {
            heroLongPressTriggered = false
            return
        }

        lastInteraction = Date()
        mainFocus = .hero
        withAnimation(.easeInOut(duration: 0.16)) {
            controlsVisible.toggle()
        }
    }

    private func handleIOSHeroDoubleTap() {
        if heroLongPressTriggered {
            heroLongPressTriggered = false
            return
        }
        toggleHeroFullscreen()
    }

    private var iosPageSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { value in
                handleIOSPageSwipe(value)
            }
    }

    private func handleIOSPageSwipe(_ value: DragGesture.Value) {
        guard !reorderSessionActive, store.pageCount > 1 else { return }
        let vertical = abs(value.translation.height)
        let horizontal = abs(value.translation.width)
        guard vertical > horizontal, vertical > 60 else { return }
        recordActivity()
        if value.translation.height < 0 {
            withAnimation(.easeInOut(duration: 0.22)) { store.changePage(1) }
        } else {
            withAnimation(.easeInOut(duration: 0.22)) { store.changePage(-1) }
        }
    }
    #endif

    #if os(macOS)
    private var macHeroTapGesture: some Gesture {
        TapGesture(count: 2)
            .exclusively(before: TapGesture(count: 1))
            .onEnded { value in
                switch value {
                case .first:
                    handleMacHeroDoubleClick()
                case .second:
                    handleMacHeroSingleClick()
                }
            }
    }

    private func handleMacHeroSingleClick() {
        if macActivationClickGuard.consumeActivationClick(in: NSApp.keyWindow) {
            recordActivity()
            return
        }

        lastInteraction = Date()
        mainFocus = .hero
        withAnimation(.easeInOut(duration: 0.16)) {
            controlsVisible.toggle()
        }
    }

    private func handleMacHeroDoubleClick() {
        if macActivationClickGuard.consumeActivationClick(in: NSApp.keyWindow) {
            recordActivity()
            return
        }
        toggleHeroFullscreen()
    }
    #endif

    private func fullscreenOverlayPadding(
        _ base: EdgeInsets,
        safeAreaInsets: EdgeInsets
    ) -> EdgeInsets {
        #if os(iOS)
        guard store.mode == .fullscreen else { return base }
        return EdgeInsets(
            top: base.top + safeAreaInsets.top,
            leading: base.leading + safeAreaInsets.leading,
            bottom: base.bottom + safeAreaInsets.bottom,
            trailing: base.trailing + safeAreaInsets.trailing
        )
        #else
        return base
        #endif
    }

    private var heroInfoPadding: EdgeInsets {
        #if os(iOS)
        EdgeInsets(top: 16, leading: 16, bottom: store.mode == .fullscreen ? 26 : 16, trailing: 16)
        #else
        EdgeInsets(top: 28, leading: 28, bottom: 28, trailing: 28)
        #endif
    }

    private var heroBrandVisible: Bool {
        #if os(iOS)
        store.mode != .fullscreen
        #else
        true
        #endif
    }

    private var heroBrandPadding: EdgeInsets {
        #if os(iOS)
        EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
        #else
        EdgeInsets(top: 22, leading: 22, bottom: 22, trailing: 22)
        #endif
    }

    private var heroBrandSpacing: CGFloat {
        #if os(iOS)
        8
        #else
        10
        #endif
    }

    private var heroBrandMarkSize: CGFloat {
        #if os(iOS)
        22
        #else
        28
        #endif
    }

    private var heroBrandTitleFont: Font {
        #if os(iOS)
        .caption2.bold()
        #else
        .caption.bold()
        #endif
    }

    private var heroBrandSubtitleFont: Font {
        #if os(iOS)
        .system(size: 9, weight: .medium)
        #else
        .caption2
        #endif
    }

    private func modeSystemImage(_ value: WallMode) -> String {
        switch value {
        case .four: return "square.grid.2x2"
        case .five: return "square.grid.3x3"
        case .six: return "square.grid.3x3.fill"
        case .seven: return "square.grid.4x3.fill"
        case .fullscreen: return "arrow.up.left.and.arrow.down.right"
        }
    }

    private func sourceFilterSystemImage(_ filter: ChannelSourceFilter) -> String {
        switch filter {
        case .all: return "rectangle.stack"
        case .iptv: return "globe"
        case .go2rtc: return "video"
        }
    }

    private func channelScopeLabel(_ category: ChannelCategory) -> String {
        let title = category == .favorites ? localized("我的最愛") : localized("全部頻道")
        let count = store.channelCount(category: category, sourceFilter: store.sourceFilter)
        return "\(title)（\(count)）"
    }

    private func channelSourceLabel(_ sourceFilter: ChannelSourceFilter) -> String {
        let count = store.channelCount(category: store.category, sourceFilter: sourceFilter)
        return "\(sourceFilter.displayName)（\(count)）"
    }

    @ViewBuilder
    private func filterMenuLabel(_ title: String, isSelected: Bool, systemImage: String) -> some View {
        #if os(macOS)
        Text(isSelected ? "\(title) ✓" : title)
        #else
        Label(title, systemImage: isSelected ? "checkmark" : systemImage)
        #endif
    }

    private var availableWallModes: [WallMode] {
        #if os(macOS)
        [.four, .five, .six, .seven]
        #else
        [.four, .five, .six, .seven]
        #endif
    }

    private func restoreFromICloud() {
        onboardingMessage = localized("正在從 iCloud 尋找你的播放牆…")
        store.setCloudLibrarySyncEnabled(true)
        Task {
            await store.syncCloudLibraryIfNeeded(force: true)
            if store.featured != nil {
                onboardingMessage = nil
            } else if let error = store.cloudLibraryError, !error.isEmpty {
                onboardingMessage = error
            } else {
                #if !os(macOS)
                onboardingMessage = localized("iCloud 中目前沒有可恢復的頻道；請匯入你有權使用的 M3U 網址。")
                #else
                onboardingMessage = localized("iCloud 中目前沒有可恢復的頻道；你也可以探索公開頻道或匯入 M3U 網址。")
                #endif
            }
        }
    }

    #if os(macOS)
    private func loadStarterChannels() {
        recordActivity()
        onboardingMessage = localized("正在加入新手推薦頻道…")
        do {
            try store.addStarterChannels()
            onboardingMessage = nil
            mainFocus = .hero
        } catch {
            onboardingMessage = error.localizedDescription
        }
    }
    #endif

    private var emptyState: some View {
        #if !os(macOS)
        VStack(spacing: 24) {
            OnboardingWallPreview()
                .frame(width: 360, height: 210)

            VStack(spacing: 6) {
                Text("建立你的第一面 IPTV Wall")
                    .font(.largeTitle.bold())
                Text("你的播放清單，你的內容")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(localized("匯入你有權使用的 M3U 播放清單，開始建立多畫面播放牆。"))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if store.isLoading {
                ProgressView("正在準備頻道庫…")
            }

            if let onboardingMessage {
                Text(onboardingMessage)
                    .font(.callout)
                    .foregroundStyle(store.cloudLibraryError == nil ? Color.secondary : Color.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 680)
            }

            Button {
                m3uManagerPresented = true
            } label: {
                Label(localized("匯入 M3U 網址"), systemImage: "link.badge.plus")
            }
            .buttonStyle(TVControlButtonStyle(active: true))
            .disabled(store.isLoading)
            .focused($mainFocus, equals: .m3uManager)

            Button {
                restoreFromICloud()
            } label: {
                Label(localized("從 iCloud 恢復"), systemImage: "icloud.and.arrow.down")
            }
            .buttonStyle(TVControlButtonStyle(active: false))

            Text(localized("IPTV Wall Player 不提供頻道或影音內容。請只使用你有權播放的來源。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 680)
        }
        .padding(36)
        #else
        VStack(spacing: 24) {
            OnboardingWallPreview()
                .frame(width: 360, height: 210)

            VStack(spacing: 6) {
                Text("建立你的第一面 IPTV Wall")
                    .font(.largeTitle.bold())
                Text("一覽無遺千萬頻")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(localized("先載入 16 個公開精選新聞頻道，立即體驗 5×5 播放牆。"))
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            if store.isLoading {
                ProgressView("正在準備頻道庫…")
            }

            if let onboardingMessage {
                Text(onboardingMessage)
                    .font(.callout)
                    .foregroundStyle(store.cloudLibraryError == nil ? Color.secondary : Color.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 680)
            }

            Button {
                loadStarterChannels()
            } label: {
                Label(
                    localized(store.isAddingStarterChannels ? "加入中…" : "載入新手推薦頻道（16 台）"),
                    systemImage: "sparkles.tv"
                )
            }
            .buttonStyle(TVControlButtonStyle(active: true))
            .disabled(store.isLoading || store.isAddingStarterChannels)
            .focused($mainFocus, equals: .starterChannels)

            Text(localized("按下後會將頻道加入你的頻道庫；你可以稍後刪除或排序。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button {
                    restoreFromICloud()
                } label: {
                    Label(localized("從 iCloud 恢復"), systemImage: "icloud.and.arrow.down")
                }
                .buttonStyle(TVControlButtonStyle(active: false))

                Button {
                    channelExplorerPresented = true
                } label: {
                    Label(localized("探索公開頻道"), systemImage: "safari")
                }
                .buttonStyle(TVControlButtonStyle(active: false))

                Button {
                    m3uManagerPresented = true
                } label: {
                    Label(localized("匯入 M3U 網址"), systemImage: "link.badge.plus")
                }
                .buttonStyle(TVControlButtonStyle(active: true))
                .focused($mainFocus, equals: .m3uManager)
            }
        }
        .padding(36)
        #endif
    }

    private func perimeterCells(count: Int) -> [(row: Int, column: Int)] {
        var cells: [(Int, Int)] = []
        for row in 0..<count {
            for column in 0..<count {
                let isEdge = row == 0 || row == count - 1 || column == 0 || column == count - 1
                if isEdge { cells.append((row, column)) }
            }
        }
        return cells
    }

    private func reorderToolbarAtBottom(count: Int) -> Bool {
        let activeChannelID: String?
        if let reorderingChannelID {
            activeChannelID = reorderingChannelID
        } else if case .miniCenter(let channelID) = mainFocus {
            activeChannelID = channelID
        } else {
            activeChannelID = nil
        }

        guard let activeChannelID,
              let channelIndex = store.pageChannels.firstIndex(where: { $0.id == activeChannelID }) else {
            return false
        }
        let cells = perimeterCells(count: count)
        guard cells.indices.contains(channelIndex) else { return false }
        return cells[channelIndex].row < count / 2
    }

    private func flag(_ code: String) -> String {
        guard code.count == 2 else { return "◎" }
        return code.unicodeScalars.compactMap { UnicodeScalar(127397 + Int($0.value)).map(String.init) }.joined()
    }

    private func countryName(_ code: String) -> String {
        if code == "INT" { return localized("國際") }
        if code == "M3U" { return localized("播放清單") }
        return Locale.autoupdatingCurrent.localizedString(forRegionCode: code) ?? code
    }

    private var heroMuted: Bool {
        #if os(macOS)
        return autoAudioDuckingEnabled && autoMutedByOtherAudio
        #else
        return false
        #endif
    }

    private static func isLocalIPTV(_ channel: NewsChannel) -> Bool {
        guard channel.url.path.contains("/live/") else { return false }
        guard let host = channel.url.host else { return false }
        return host.hasPrefix("192.168.")
            || host.hasPrefix("10.")
            || host.hasPrefix("172.16.")
            || host.hasPrefix("172.17.")
            || host.hasPrefix("172.18.")
            || host.hasPrefix("172.19.")
            || host.hasPrefix("172.20.")
            || host.hasPrefix("172.21.")
            || host.hasPrefix("172.22.")
            || host.hasPrefix("172.23.")
            || host.hasPrefix("172.24.")
            || host.hasPrefix("172.25.")
            || host.hasPrefix("172.26.")
            || host.hasPrefix("172.27.")
            || host.hasPrefix("172.28.")
            || host.hasPrefix("172.29.")
            || host.hasPrefix("172.30.")
            || host.hasPrefix("172.31.")
    }

    private func recordActivity() {
        lastInteraction = Date()
        if !controlsVisible {
            withAnimation(.easeIn(duration: 0.16)) { controlsVisible = true }
        }
    }

    private func recordPointerActivity() {
        pointerInsideWindow = true
        recordActivity()
    }

    private func recordPointerExit() {
        pointerInsideWindow = false
        lastInteraction = Date()
    }

    private var volumePercent: Int {
        Int((heroPlaybackVolume * 100).rounded())
    }

    private var totalPlaybackSeconds: TimeInterval {
        persistedPlaybackSeconds + pendingPlaybackSeconds
    }

    private func accountPlaybackTime(until now: Date, persist: Bool = false) {
        let elapsed = max(0, min(now.timeIntervalSince(lastPlaybackAccountingAt), 2))
        if scenePhase == .active, !allPlaybackPaused, store.featured != nil {
            pendingPlaybackSeconds += elapsed
        }
        lastPlaybackAccountingAt = now

        if persist || now.timeIntervalSince(lastPlaybackPersistenceAt) >= 30 {
            persistedPlaybackSeconds += pendingPlaybackSeconds
            pendingPlaybackSeconds = 0
            lastPlaybackPersistenceAt = now
        }
    }

    private func resumePlayback() {
        #if os(macOS)
        autoMutedByOtherAudio = false
        externalAudioActiveSince = nil
        externalAudioInactiveSince = Date()
        externalAudioActiveSignature = ""
        #endif
        NotificationCenter.default.post(name: .newsWallResumePlayback, object: nil)
    }

    private func toggleAllPlayback() {
        allPlaybackPaused.toggle()
        if !allPlaybackPaused {
            resumePlayback()
        }
    }

    #if os(macOS)
    private func updateAutoMuteState(now: Date) {
        guard autoAudioDuckingEnabled else {
            autoMutedByOtherAudio = false
            externalAudioActiveSince = nil
            externalAudioInactiveSince = nil
            externalAudioActiveSignature = ""
            return
        }

        let activeSources = MacExternalAudioMonitor.activeOtherAudioSources()
        let activeSignature = activeSources.sorted().joined(separator: "|")
        let otherAudioIsActive = !activeSources.isEmpty

        if otherAudioIsActive {
            externalAudioInactiveSince = nil
            if externalAudioActiveSignature != activeSignature {
                externalAudioActiveSignature = activeSignature
                externalAudioActiveSince = now
            } else if externalAudioActiveSince == nil {
                externalAudioActiveSince = now
            }
            if !autoMutedByOtherAudio,
               let activeSince = externalAudioActiveSince,
               now.timeIntervalSince(activeSince) >= 3 {
                autoMutedByOtherAudio = true
            }
        } else {
            externalAudioActiveSince = nil
            externalAudioActiveSignature = ""
            if externalAudioInactiveSince == nil {
                externalAudioInactiveSince = now
            }
            if autoMutedByOtherAudio,
               let inactiveSince = externalAudioInactiveSince,
               now.timeIntervalSince(inactiveSince) >= 1 {
                autoMutedByOtherAudio = false
            }
        }
    }

    private func toggleAutoAudioDucking() {
        autoAudioDuckingEnabled.toggle()
        if !autoAudioDuckingEnabled {
            autoMutedByOtherAudio = false
            externalAudioActiveSince = nil
            externalAudioInactiveSince = Date()
            externalAudioActiveSignature = ""
        }
    }
    #endif

    private func restoreMainFocus() {
        recordActivity()
        if mainFocus == .sourceFilter {
            mainFocus = .hero
            return
        }
        if let channelID = quickActionReturnFocusChannelID {
            quickActionReturnFocusChannelID = nil
            if store.mode != .fullscreen,
               store.pageChannels.contains(where: { $0.id == channelID }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    mainFocus = .miniCenter(channelID)
                }
                return
            }
        }
        mainFocus = .hero
    }

    private var focusCategory: ChannelCategory {
        store.category == .m3u ? .all : store.category
    }

private var heroHasFocus: Bool {
        switch mainFocus {
        case .hero, .starterChannels, .category, .mode, .resume, .m3uManager, .explorer, .favorite, .favoriteEarlier, .favoriteLater, .previous, .next, .volume, .autoDucking, .sourceFilter: return true
        case .miniCenter, .none: return false
        }
    }

    private var unfavoriteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingUnfavorite != nil },
            set: { if !$0 { pendingUnfavorite = nil } }
        )
    }

    private var deleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: {
                if !$0 {
                    pendingDelete = nil
                    pendingDeleteIndex = nil
                }
            }
        )
    }

    #if os(tvOS)
    private var miniActionMenuPresented: Binding<Bool> {
        Binding(
            get: { miniActionChannel != nil },
            set: { isPresented in
                guard !isPresented else { return }
                let channelID = miniActionChannel?.id
                miniActionChannel = nil
                if let channelID {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        if store.pageChannels.contains(where: { $0.id == channelID }) {
                            mainFocus = .miniCenter(channelID)
                        }
                    }
                }
            }
        )
    }

    private func showMiniActions(_ channel: NewsChannel) {
        recordActivity()
        mainFocus = .miniCenter(channel.id)
        miniActionChannel = channel
    }

    private func dismissMiniActionMenu(then action: @escaping () -> Void) {
        miniActionChannel = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: action)
    }
    #else
    private func showMiniActions(_ channel: NewsChannel) {}
    #endif

    private func requestFavoriteToggle(_ channel: NewsChannel) {
        recordActivity()
        if store.isFavorite(channel) {
            pendingUnfavorite = channel
        } else {
            store.toggleFavorite(channel)
        }
    }

    @ViewBuilder
    private func heroChannelActionButtons(_ channel: NewsChannel) -> some View {
        Button {
            dismissHeroChannelActions {
                requestFavoriteToggle(channel)
            }
        } label: {
            Label(
                localized(store.isFavorite(channel) ? "從我的最愛移除" : "加入我的最愛"),
                systemImage: store.isFavorite(channel) ? "star.slash" : "star"
            )
        }

        Button {
            dismissHeroChannelActions {
                showChannelInfo(channel)
            }
        } label: {
            Label(localized("頻道資訊"), systemImage: "info.circle")
        }

        Button {
            dismissHeroChannelActions {
                toggleAllPlayback()
            }
        } label: {
            Label(
                localized(allPlaybackPaused ? "繼續播放" : "全部暫停"),
                systemImage: allPlaybackPaused ? "play.fill" : "pause.fill"
            )
        }

        #if os(macOS)
        Button {
            dismissHeroChannelActions {
                volumeSettingsPresented = true
            }
        } label: {
            Label("\(localized("正常播放音量")) · \(volumePercent)%", systemImage: "speaker.wave.2.fill")
        }

        Button {
            dismissHeroChannelActions {
                toggleAutoAudioDucking()
            }
        } label: {
            Label(
                localized(autoAudioDuckingEnabled ? "自動靜音已啟用" : "自動靜音已停用"),
                systemImage: autoAudioDuckingEnabled ? "speaker.wave.2.fill" : "speaker.slash"
            )
        }
        #endif

        if store.pageCount > 1 {
            Button {
                dismissHeroChannelActions {
                    store.changePage(-1)
                }
            } label: {
                Label(localized("上一組"), systemImage: "chevron.left")
            }

            Button {
                dismissHeroChannelActions {
                    store.changePage(1)
                }
            } label: {
                Label(localized("下一組"), systemImage: "chevron.right")
            }
        }

        Section(localized("顯示範圍")) {
            Button {
                dismissHeroChannelActions {
                    store.selectCategory(.all)
                }
            } label: {
                filterMenuLabel(
                    channelScopeLabel(.all),
                    isSelected: store.category == .all,
                    systemImage: "rectangle.stack"
                )
            }

            Button {
                dismissHeroChannelActions {
                    store.selectCategory(.favorites)
                }
            } label: {
                filterMenuLabel(
                    channelScopeLabel(.favorites),
                    isSelected: store.category == .favorites,
                    systemImage: "star"
                )
            }
        }

        Section(localized("頻道來源")) {
            ForEach(ChannelSourceFilter.allCases) { filter in
                Button {
                    dismissHeroChannelActions {
                        store.selectSourceFilter(filter)
                    }
                } label: {
                    filterMenuLabel(
                        channelSourceLabel(filter),
                        isSelected: store.sourceFilter == filter,
                        systemImage: sourceFilterSystemImage(filter)
                    )
                }
            }
        }

        ForEach(availableWallModes) { mode in
            Button {
                dismissHeroChannelActions {
                    selectHeroWallMode(mode)
                }
            } label: {
                Label(
                    localized(mode.rawValue),
                    systemImage: store.mode == mode ? "checkmark" : modeSystemImage(mode)
                )
            }
        }

        Button {
            dismissHeroChannelActions {
                m3uManagerPresented = true
            }
        } label: {
            Label(localized("頻道庫與來源"), systemImage: "rectangle.stack.badge.plus")
        }

        Button(role: .destructive) {
            dismissHeroChannelActions {
                requestChannelDelete(channel)
            }
        } label: {
            Label(localized("從播放牆移除"), systemImage: "trash")
        }

        Button(localized("取消"), role: .cancel) {}
    }

    @ViewBuilder
    private func heroContextMenuItems(_ channel: NewsChannel) -> some View {
        Button {
            performHeroContextAction {
                requestFavoriteToggle(channel)
            }
        } label: {
            Label(
                localized(store.isFavorite(channel) ? "從我的最愛移除" : "加入我的最愛"),
                systemImage: store.isFavorite(channel) ? "star.slash" : "star"
            )
        }

        Button {
            performHeroContextAction {
                showChannelInfo(channel)
            }
        } label: {
            Label(localized("頻道資訊"), systemImage: "info.circle")
        }

        Divider()

        Button {
            performHeroContextAction {
                toggleAllPlayback()
            }
        } label: {
            Label(
                localized(allPlaybackPaused ? "繼續播放" : "全部暫停"),
                systemImage: allPlaybackPaused ? "play.fill" : "pause.fill"
            )
        }

        #if os(macOS)
        Button {
            performHeroContextAction {
                volumeSettingsPresented = true
            }
        } label: {
            Label("\(localized("正常播放音量")) · \(volumePercent)%", systemImage: "speaker.wave.2.fill")
        }

        Button {
            performHeroContextAction {
                toggleAutoAudioDucking()
            }
        } label: {
            Label(
                localized(autoAudioDuckingEnabled ? "自動靜音已啟用" : "自動靜音已停用"),
                systemImage: autoAudioDuckingEnabled ? "speaker.wave.2.fill" : "speaker.slash"
            )
        }
        #endif

        Divider()

        if store.pageCount > 1 {
            Button {
                performHeroContextAction {
                    store.changePage(-1)
                }
            } label: {
                Label(localized("上一組"), systemImage: "chevron.left")
            }

            Button {
                performHeroContextAction {
                    store.changePage(1)
                }
            } label: {
                Label(localized("下一組"), systemImage: "chevron.right")
            }
        }

        Section(localized("顯示範圍")) {
            Button {
                performHeroContextAction {
                    store.selectCategory(.all)
                }
            } label: {
                filterMenuLabel(
                    channelScopeLabel(.all),
                    isSelected: store.category == .all,
                    systemImage: "rectangle.stack"
                )
            }

            Button {
                performHeroContextAction {
                    store.selectCategory(.favorites)
                }
            } label: {
                filterMenuLabel(
                    channelScopeLabel(.favorites),
                    isSelected: store.category == .favorites,
                    systemImage: "star"
                )
            }
        }

        Section(localized("頻道來源")) {
            ForEach(ChannelSourceFilter.allCases) { filter in
                Button {
                    performHeroContextAction {
                        store.selectSourceFilter(filter)
                    }
                } label: {
                    filterMenuLabel(
                        channelSourceLabel(filter),
                        isSelected: store.sourceFilter == filter,
                        systemImage: sourceFilterSystemImage(filter)
                    )
                }
            }
        }

        ForEach(availableWallModes) { mode in
            Button {
                performHeroContextAction {
                    selectHeroWallMode(mode)
                }
            } label: {
                Label(
                    localized(mode.rawValue),
                    systemImage: store.mode == mode ? "checkmark" : modeSystemImage(mode)
                )
            }
        }

        Button {
            performHeroContextAction {
                m3uManagerPresented = true
            }
        } label: {
            Label(localized("頻道庫與來源"), systemImage: "rectangle.stack.badge.plus")
        }

        Divider()

        Button(role: .destructive) {
            performHeroContextAction {
                requestChannelDelete(channel)
            }
        } label: {
            Label(localized("從播放牆移除"), systemImage: "trash")
        }
    }

    #if os(iOS)
    private func heroActionsSheet(_ channel: NewsChannel) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(channel.name)
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(flag(channel.country)) \(countryName(channel.country))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                    Divider()
                    heroContextMenuItems(channel)
                }
                .buttonStyle(HeroSheetActionButtonStyle())
                .padding(.horizontal, 12)
                .padding(.bottom, 24)
            }
            .navigationTitle(localized("頻道選項"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        heroChannelActionsPresented = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(localized("取消"))
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }
    #endif

    #if os(tvOS)
    @ViewBuilder
    private func miniChannelActionButtons(_ channel: NewsChannel) -> some View {
        if reorderSessionActive {
            Button {
                dismissMiniActionMenu(then: { finishChannelReordering() })
            } label: {
                Label(localized("完成調整順序"), systemImage: "checkmark")
            }

            Button {
                dismissMiniActionMenu(then: { cancelChannelReordering() })
            } label: {
                Label(localized("取消調整"), systemImage: "xmark")
            }
        } else {
            Button {
                dismissMiniActionMenu(then: { requestFavoriteToggle(channel) })
            } label: {
                Label(
                    localized(store.isFavorite(channel) ? "從我的最愛移除" : "加入我的最愛"),
                    systemImage: store.isFavorite(channel) ? "star.slash" : "star"
                )
            }

            Button {
                dismissMiniActionMenu(then: { showChannelInfo(channel) })
            } label: {
                Label(localized("頻道資訊"), systemImage: "info.circle")
            }

            Button {
                dismissMiniActionMenu(then: { beginChannelReordering(channel) })
            } label: {
                Label(
                    localized("調整頻道位置"),
                    systemImage: "arrow.up.and.down.and.arrow.left.and.right"
                )
            }

            Button(role: .destructive) {
                dismissMiniActionMenu(then: { requestChannelDelete(channel) })
            } label: {
                Label(localized("從播放牆移除"), systemImage: "trash")
            }
        }

        Button(localized("取消"), role: .cancel) {}
    }
    #endif

    private func dismissHeroChannelActions(then action: @escaping () -> Void) {
        heroChannelActionsPresented = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: action)
    }

    private func showHeroChannelActions() {
        recordActivity()
        heroChannelActionsPresented = true
    }

    private func performHeroContextAction(_ action: @escaping () -> Void) {
        recordActivity()
        #if os(iOS)
        heroChannelActionsPresented = false
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: action)
    }

    private func toggleHeroFullscreen() {
        recordActivity()
        if store.mode == .fullscreen {
            let restoredMode = WallMode(rawValue: modeBeforeFullscreenRawValue) ?? .five
            let targetMode = restoredMode == .fullscreen ? WallMode.five : restoredMode
            store.selectMode(targetMode)
            store.page = min(pageBeforeFullscreen, max(0, store.pageCount - 1))
        } else {
            modeBeforeFullscreenRawValue = store.mode.rawValue
            pageBeforeFullscreen = store.page
            PlayerPool.shared.retainReleasedSessions(for: 3 * 60)
            store.selectMode(.fullscreen)
            store.page = min(pageBeforeFullscreen, max(0, store.pageCount - 1))
        }
        mainFocus = .hero
    }

    private func handleExitCommand() {
        if reorderSessionActive {
            cancelChannelReordering()
            return
        }

        #if os(macOS)
        if store.mode == .fullscreen {
            toggleHeroFullscreen()
        }
        #endif
    }

    private func selectHeroWallMode(_ mode: WallMode) {
        guard mode != .fullscreen else { return }
        let currentPage = store.mode == .fullscreen ? pageBeforeFullscreen : store.page
        modeBeforeFullscreenRawValue = mode.rawValue
        store.selectMode(mode)
        store.page = min(currentPage, max(0, store.pageCount - 1))
        mainFocus = .hero
    }

    private func showChannelInfo(_ channel: NewsChannel) {
        recordActivity()
        quickActionReturnFocusChannelID = channel.id
        channelInfoPresented = channel
    }

    private func requestChannelDelete(_ channel: NewsChannel) {
        recordActivity()
        pendingDeleteIndex = store.pageChannels.firstIndex(where: { $0.id == channel.id })
        pendingDelete = channel
    }

    private func restoreMiniFocusAfterDelete(previousIndex: Int?) {
        guard store.mode != .fullscreen,
              !store.pageChannels.isEmpty,
              let previousIndex else {
            mainFocus = .hero
            return
        }

        let replacementIndex = min(previousIndex, store.pageChannels.count - 1)
        let replacement = store.pageChannels[replacementIndex]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            recordActivity()
            mainFocus = .miniCenter(replacement.id)
        }
    }

    private func handleMoveCommand(_ direction: WallMoveDirection) {
        recordActivity()
        if let channelID = reorderingChannelID {
            moveReorderingChannel(channelID: channelID, direction: direction)
            return
        }

        if shouldEnterHero(from: mainFocus, moving: direction) {
            mainFocus = .hero
            return
        }

        guard direction == .up,
              store.mode != .fullscreen,
              let firstMiniChannel = store.pageChannels.first else { return }

        switch mainFocus {
        case .hero, .starterChannels, .category, .mode, .resume, .m3uManager, .explorer, .favorite, .favoriteEarlier, .favoriteLater, .previous, .next, .volume, .autoDucking, .sourceFilter:
            mainFocus = .miniCenter(firstMiniChannel.id)
        case .miniCenter, .none:
            break
        }
    }

    private func shouldEnterHero(from focus: MainFocus?, moving direction: WallMoveDirection) -> Bool {
        let channelID: String
        switch focus {
        case .miniCenter(let id): channelID = id
        default: return false
        }

        guard store.mode != .fullscreen,
              let index = store.pageChannels.firstIndex(where: { $0.id == channelID }) else { return false }

        let count = store.mode.gridDimension
        let cell = perimeterCells(count: count)[index]
        let last = count - 1
        let alignedWithHero = (1..<last)

        return (cell.row == 0 && alignedWithHero.contains(cell.column) && direction == .down)
            || (cell.row == last && alignedWithHero.contains(cell.column) && direction == .up)
            || (cell.column == 0 && alignedWithHero.contains(cell.row) && direction == .right)
            || (cell.column == last && alignedWithHero.contains(cell.row) && direction == .left)
    }

    private func handleMiniPrimaryAction(_ channel: NewsChannel) {
        #if os(macOS)
        if macActivationClickGuard.consumeActivationClick(in: NSApp.keyWindow) {
            recordActivity()
            return
        }
        #endif

        recordActivity()
        guard reorderSessionActive else {
            store.center(channel)
            return
        }

        if reorderingChannelID == channel.id {
            reorderingChannelID = nil
            recordActivity()
        } else if let sourceID = reorderingChannelID {
            moveReorderingChannel(sourceID: sourceID, to: channel)
        } else {
            reorderingChannelID = channel.id
            recordActivity()
        }
    }

    private func beginChannelReordering(_ channel: NewsChannel) {
        recordActivity()
        reorderCategory = focusCategory
        reorderSnapshot = store.channelOrderSnapshot(for: focusCategory)
        reorderSessionActive = true
        reorderingChannelID = nil
        mainFocus = .miniCenter(channel.id)
    }

    private func finishChannelReordering() {
        guard reorderSessionActive else { return }
        let channelID = reorderingChannelID
        reorderSessionActive = false
        reorderingChannelID = nil
        reorderCategory = nil
        reorderSnapshot = []
        recordActivity()
        DispatchQueue.main.async {
            if let channelID, store.pageChannels.contains(where: { $0.id == channelID }) {
                mainFocus = .miniCenter(channelID)
            }
        }
    }

    private func cancelChannelReordering() {
        guard reorderSessionActive,
              let category = reorderCategory else { return }
        store.restoreChannelOrder(reorderSnapshot, for: category)
        let channelID = reorderingChannelID
        reorderSessionActive = false
        reorderingChannelID = nil
        reorderCategory = nil
        reorderSnapshot = []
        recordActivity()
        DispatchQueue.main.async {
            if let channelID, store.pageChannels.contains(where: { $0.id == channelID }) {
                mainFocus = .miniCenter(channelID)
            } else {
                mainFocus = .hero
            }
        }
    }

    private func moveReorderingChannel(sourceID: String, to destination: NewsChannel) {
        guard let category = reorderCategory,
              let source = store.filteredChannels.first(where: { $0.id == sourceID }),
              source.id != destination.id else { return }
        store.swapChannelOrder(source, with: destination, in: category)
        reorderingChannelID = source.id
        recordActivity()
        DispatchQueue.main.async {
            mainFocus = .miniCenter(source.id)
        }
    }

    private func moveReorderingChannel(channelID: String, direction: WallMoveDirection) {
        guard let source = store.filteredChannels.first(where: { $0.id == channelID }),
              let destination = reorderDestination(for: source, direction: direction) else { return }
        moveReorderingChannel(sourceID: channelID, to: destination)
    }

    private func reorderDestination(
        for source: NewsChannel,
        direction: WallMoveDirection
    ) -> NewsChannel? {
        if let pageIndex = store.pageChannels.firstIndex(where: { $0.id == source.id }) {
            let count = store.mode.gridDimension
            let cells = perimeterCells(count: count)
            guard cells.indices.contains(pageIndex) else { return nil }
            let current = cells[pageIndex]
            let target: (row: Int, column: Int)
            switch direction {
            case .left: target = (current.row, current.column - 1)
            case .right: target = (current.row, current.column + 1)
            case .up: target = (current.row - 1, current.column)
            case .down: target = (current.row + 1, current.column)
            }
            if let targetIndex = cells.firstIndex(where: {
                $0.row == target.row && $0.column == target.column
            }), store.pageChannels.indices.contains(targetIndex) {
                return store.pageChannels[targetIndex]
            }
        }

        guard let globalIndex = store.filteredChannels.firstIndex(where: { $0.id == source.id }) else {
            return nil
        }
        let delta: Int
        switch direction {
        case .left, .up: delta = -1
        case .right, .down: delta = 1
        }
        let destinationIndex = globalIndex + delta
        guard store.filteredChannels.indices.contains(destinationIndex) else { return nil }
        return store.filteredChannels[destinationIndex]
    }
}

#if os(macOS)
private enum MacExternalAudioMonitor {
    private static let ignoredBundleIDs: Set<String> = [
        "com.apple.audio.coreaudiod",
        "com.apple.audio.AudioComponentRegistrar",
        "com.apple.audio.AudioMIDISetup",
        "com.apple.CoreAudio",
        "com.apple.avconferenced",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui"
    ]

    private static let ignoredBundlePrefixes = [
        "com.apple.audio.",
        "com.apple.audioanalytics",
        "com.apple.audioanalyticsd",
        "com.apple.mediaanalysisd"
    ]

    static func isOtherAppPlayingAudio() -> Bool {
        !activeOtherAudioSources().isEmpty
    }

    static func activeOtherAudioSources() -> Set<String> {
        let processIDs = audioProcessObjectIDs()
        let currentPID = getpid()
        let ownBundleID = Bundle.main.bundleIdentifier
        var sources: Set<String> = []

        for processID in processIDs {
            guard let pid = pid(for: processID), pid != currentPID else { continue }
            guard let bundleID = bundleID(for: processID), !bundleID.isEmpty else { continue }
            guard bundleID != ownBundleID,
                  !shouldIgnore(bundleID: bundleID) else { continue }
            guard let isRunningOutput = uint32Property(kAudioProcessPropertyIsRunningOutput, objectID: processID) else { continue }
            if isRunningOutput != 0 {
                sources.insert(normalizedSourceID(bundleID))
            }
        }

        return sources
    }

    private static func shouldIgnore(bundleID: String) -> Bool {
        if ignoredBundleIDs.contains(bundleID) { return true }
        if ignoredBundlePrefixes.contains(where: { bundleID.hasPrefix($0) }) { return true }
        if bundleID.hasPrefix("com.apple.") { return true }

        return false
    }

    private static func normalizedSourceID(_ bundleID: String) -> String {
        let helperMarkers = [
            ".helper",
            ".Helper",
            " Helper",
            ".renderer",
            ".Renderer"
        ]

        for marker in helperMarkers {
            if let range = bundleID.range(of: marker) {
                return String(bundleID[..<range.lowerBound])
            }
        }

        return bundleID
    }

    private static func audioProcessObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr,
              dataSize >= MemoryLayout<AudioObjectID>.size else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processIDs = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        let status = processIDs.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return kAudioHardwareIllegalOperationError }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                baseAddress
            )
        }

        guard status == noErr else { return [] }
        return processIDs.filter { $0 != AudioObjectID(kAudioObjectUnknown) }
    }

    private static func pid(for processID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = pid_t(0)
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(processID, &address, 0, nil, &dataSize, &value)
        return status == noErr ? value : nil
    }

    private static func bundleID(for processID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(processID, &address, 0, nil, &dataSize) == noErr else {
            return nil
        }

        var unmanagedValue: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(processID, &address, 0, nil, &dataSize, &unmanagedValue)
        guard status == noErr, let unmanagedValue else { return nil }
        return unmanagedValue.takeRetainedValue() as String
    }

    private static func uint32Property(_ selector: AudioObjectPropertySelector, objectID: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = UInt32(0)
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value)
        return status == noErr ? value : nil
    }
}
#endif

private enum MainFocus: Hashable {
    case hero
    case starterChannels
    case category(ChannelCategory)
    case mode(WallMode)
    case resume
    case m3uManager
    case explorer
    case favorite
    case favoriteEarlier
    case favoriteLater
    case previous
    case next
    case volume
    case autoDucking
    case sourceFilter
    case miniCenter(String)
}

private enum WallMoveDirection {
    case left
    case right
    case up
    case down
}

private struct OnboardingWallPreview: View {
    private let symbols = [
        "globe",
        "newspaper.fill",
        "chart.line.uptrend.xyaxis",
        "antenna.radiowaves.left.and.right"
    ]

    var body: some View {
        ZStack {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4),
                spacing: 6
            ) {
                ForEach(0..<16, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 9)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.blue.opacity(index.isMultiple(of: 3) ? 0.48 : 0.24),
                                    Color.white.opacity(0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay {
                            Image(systemName: symbols[index % symbols.count])
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.46))
                        }
                        .aspectRatio(16 / 9, contentMode: .fit)
                }
            }

            RoundedRectangle(cornerRadius: 18)
                .fill(
                    LinearGradient(
                        colors: [Color.blue.opacity(0.92), Color.indigo.opacity(0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 174, height: 104)
                .overlay {
                    VStack(spacing: 7) {
                        IPTVWallLogoMark(size: 30)
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("IPTV WALL")
                                .font(.caption.bold())
                                .tracking(1.4)
                            Text("Player")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.white.opacity(0.82))
                        }
                    }
                    .foregroundStyle(.white)
                }
                .shadow(color: Color.blue.opacity(0.35), radius: 18)
        }
        .padding(8)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 22))
        .accessibilityHidden(true)
    }
}

private struct IPTVWallLogoMark: View {
    enum Style {
        case white
        case brandBlue
    }

    let size: CGFloat
    var style: Style = .white

    var body: some View {
        ZStack {
            if style == .brandBlue {
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
            }

            logoGrid
                .frame(width: gridSize, height: gridSize)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var logoGrid: some View {
        Grid(horizontalSpacing: gridSize * 0.1, verticalSpacing: gridSize * 0.1) {
            GridRow {
                logoCell
                logoCell
            }
            GridRow {
                logoCell
                logoCell
            }
        }
    }

    private var gridSize: CGFloat {
        style == .brandBlue ? size * 0.46 : size
    }

    private var logoCell: some View {
        RoundedRectangle(cornerRadius: gridSize * 0.12)
            .fill(Color.white.opacity(0.96))
    }
}

#if os(macOS)
private struct HeroVolumeSettingsView: View {
    @Binding var volume: Double
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text(localized("正常播放音量"))
                    .font(.headline)
                HStack(spacing: 14) {
                    Image(systemName: "speaker.fill")
                        .foregroundStyle(.secondary)
                    Slider(value: $volume, in: 0...1, step: 0.05) {
                        Text(localized("音量"))
                    }
                    Image(systemName: "speaker.wave.3.fill")
                        .foregroundStyle(.secondary)
                    Text("\(Int((volume * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .frame(width: 46, alignment: .trailing)
                }
            }
            .padding(28)
            .frame(width: 440)
            .navigationTitle(localized("音量"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(localized("完成")) { dismiss() }
                }
            }
        }
    }
}
#endif

private struct ChannelInfoView: View {
    let channel: NewsChannel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(channel.name)
                            .font(.title.bold())
                            .fixedSize(horizontal: false, vertical: true)
                        Label(
                            "\(flag(channel.country)) \(countryName(channel.country))",
                            systemImage: "globe"
                        )
                        .foregroundStyle(.secondary)
                    }

                    Divider()

                    informationRow(
                        title: localized("來源"),
                        value: channel.category == .m3u ? localized("M3U / HLS") : localized("HLS")
                    )
                    informationRow(
                        title: localized("串流網址"),
                        value: channel.url.absoluteString,
                        monospaced: true
                    )
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(36)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(localized("頻道資訊"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(localized("完成")) { dismiss() }
                }
            }
        }
    }

    private func informationRow(title: String, value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func flag(_ code: String) -> String {
        guard code.count == 2 else { return "◎" }
        return code.unicodeScalars.compactMap {
            UnicodeScalar(127397 + Int($0.value)).map(String.init)
        }.joined()
    }

    private func countryName(_ code: String) -> String {
        if code == "INT" { return localized("國際") }
        if code == "M3U" { return localized("播放清單") }
        return Locale.autoupdatingCurrent.localizedString(forRegionCode: code) ?? code
    }
}

private struct FeaturedSignageCard: View {
    let channel: NewsChannel
    let allPlaybackPaused: Bool
    let totalPlaybackSeconds: TimeInterval
    let autoAudioDuckingEnabled: Bool
    let autoMutedByOtherAudio: Bool

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 140 || proxy.size.height < 90
            let showSecondaryLine = proxy.size.height >= 96

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let clockPage = Int(context.date.timeIntervalSince1970 / 10).isMultiple(of: 2)

                ZStack {
                    LinearGradient(
                        colors: [
                            allPlaybackPaused ? Color.orange.opacity(0.34) : Color.blue.opacity(0.36),
                            Color.black,
                            Color.black
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    VStack(alignment: .leading, spacing: compact ? 1 : 3) {
                        HStack(spacing: compact ? 3 : 6) {
                            HStack(spacing: compact ? 2 : 4) {
                                Image(systemName: allPlaybackPaused ? "pause.fill" : "play.rectangle.fill")
                                Text(localized(allPlaybackPaused ? "已暫停" : "LIVE"))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                            }
                            .foregroundStyle(allPlaybackPaused ? .yellow : .red)
                            Spacer(minLength: 2)
                            Text(context.date, format: .dateTime.hour().minute())
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                        .font(.system(size: compact ? 8 : 11, weight: .bold))

                        if clockPage {
                            Spacer(minLength: 0)
                            Text(context.date, format: .dateTime.hour().minute())
                                .font(.system(size: compact ? 17 : 25, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.65)
                            if showSecondaryLine {
                                Text(context.date, format: .dateTime.weekday(.wide).month().day())
                                    .font(.system(size: compact ? 8 : 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.65)
                            }
                            Spacer(minLength: 0)
                        } else {
                            Spacer(minLength: 0)
                            Text(channel.name)
                                .font(.system(size: compact ? 10 : 15, weight: .bold))
                                .lineLimit(showSecondaryLine ? 2 : 1)
                                .minimumScaleFactor(0.65)
                            if showSecondaryLine {
                                Text("\(flag(channel.country)) \(countryName(channel.country))")
                                    .font(.system(size: compact ? 8 : 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.65)
                            }
                            Spacer(minLength: 0)
                        }

                        playbackFooter(compact: compact)
                    }
                    .padding(compact ? 5 : 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .clipped()
            }
        }
        .clipped()
    }

    @ViewBuilder
    private func playbackFooter(compact: Bool) -> some View {
        if compact {
            Label(formattedDuration, systemImage: "clock.arrow.circlepath")
                .font(.system(size: 7.5, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        } else {
            HStack(spacing: 10) {
                Label(
                    "\(localized("總播放")) \(formattedDuration)",
                    systemImage: "clock.arrow.circlepath"
                )
                .lineLimit(1)
                .minimumScaleFactor(0.7)

                #if os(macOS)
                Label(autoMuteText, systemImage: autoMuteSystemImage)
                    .foregroundStyle(autoMutedByOtherAudio ? .orange : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                #endif
            }
            .font(.system(size: 8.5, weight: .semibold))
        }
    }

    private var formattedDuration: String {
        let seconds = max(0, Int(totalPlaybackSeconds.rounded(.down)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
    }

    private var autoMuteText: String {
        if autoMutedByOtherAudio { return localized("自動靜音中") }
        return localized(autoAudioDuckingEnabled ? "自動靜音已啟用" : "自動靜音已停用")
    }

    private var autoMuteSystemImage: String {
        if autoMutedByOtherAudio { return "speaker.slash.fill" }
        return autoAudioDuckingEnabled ? "speaker.wave.2.fill" : "speaker.slash"
    }

    private func flag(_ code: String) -> String {
        guard code.count == 2 else { return "◎" }
        return code.unicodeScalars.compactMap {
            UnicodeScalar(127397 + Int($0.value)).map(String.init)
        }.joined()
    }

    private func countryName(_ code: String) -> String {
        if code == "INT" { return localized("國際") }
        if code == "M3U" { return localized("播放清單") }
        return Locale.autoupdatingCurrent.localizedString(forRegionCode: code) ?? code
    }
}

private struct MiniChannelView: View {
    @State private var longPressTriggered = false

    let channel: NewsChannel
    let index: Int
    let isFavorite: Bool
    let isFeatured: Bool
    let controlsVisible: Bool
    let allPlaybackPaused: Bool
    let totalPlaybackSeconds: TimeInterval
    let autoAudioDuckingEnabled: Bool
    let autoMutedByOtherAudio: Bool
    let isReorderMode: Bool
    let isBeingReordered: Bool
    let focus: FocusState<MainFocus?>.Binding
    let onPrimaryAction: () -> Void
    let onMore: () -> Void
    let onFavorite: () -> Void
    let onInfo: () -> Void
    let onBeginReorder: () -> Void
    let onFinishReorder: () -> Void
    let onCancelReorder: () -> Void
    let onDelete: () -> Void
    let onDropReorder: (String) -> Void
    let onActivity: () -> Void
    let onFailure: () -> Void

    private var isFocused: Bool {
        focus.wrappedValue == .miniCenter(channel.id)
    }

    var body: some View {
        #if os(tvOS)
        tile
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.65)
                    .onEnded { _ in
                        guard !isReorderMode else { return }
                        longPressTriggered = true
                        onActivity()
                        onMore()
                    }
            )
        #else
        tile
            .contextMenu {
                menuItems
            }
        #endif
    }

    private var tile: some View {
        interactiveTile
        .accessibilityIdentifier("mini-channel-\(channel.id)")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .focused(focus, equals: .miniCenter(channel.id))
        .platformCustomMiniFocus()
        .platformReorderDrag(
            channelID: channel.id,
            isReorderMode: isReorderMode,
            isBeingReordered: isBeingReordered,
            onDrop: onDropReorder
        )
        #if os(macOS)
        .scaleEffect(controlsVisible && isFocused ? (isBeingReordered ? 1.04 : 1.02) : 1)
        #endif
        .zIndex(controlsVisible && isFocused ? 10 : 0)
        .animation(.easeOut(duration: 0.16), value: isFocused)
        .animation(.easeOut(duration: 0.16), value: isBeingReordered)
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .inset(by: controlsVisible && isFocused ? 3 : 0.5)
                .stroke(
                    controlsVisible && isFocused ? Color.yellow : Color.white.opacity(0.15),
                    lineWidth: controlsVisible && isFocused ? (isBeingReordered ? 7 : 5) : 1
                )
                .shadow(
                    color: controlsVisible && isFocused ? Color.yellow.opacity(0.45) : .clear,
                    radius: isBeingReordered ? 8 : 4
                )
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var interactiveTile: some View {
        #if os(iOS)
        tileContent
            .contentShape(Rectangle())
            .gesture(iosMiniTapGesture)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                performPrimaryAction()
            }
        #else
        Button(action: performPrimaryAction) {
            tileContent
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #endif
    }

    private var tileContent: some View {
        ZStack {
            if isFeatured {
                FeaturedSignageCard(
                    channel: channel,
                    allPlaybackPaused: allPlaybackPaused,
                    totalPlaybackSeconds: totalPlaybackSeconds,
                    autoAudioDuckingEnabled: autoAudioDuckingEnabled,
                    autoMutedByOtherAudio: autoMutedByOtherAudio
                )
            } else {
                PlayerSurface(channel: channel, muted: true, paused: allPlaybackPaused, onFailure: onFailure)
                    .id("mini-\(channel.id)")
                    .clipped()
            }
            if !isFeatured {
                LinearGradient(colors: [.clear, .black.opacity(0.88)], startPoint: .center, endPoint: .bottom)
                VStack {
                    HStack {
                        Text(String(format: "%02d", index)).monospacedDigit()
                        Spacer()
                        Text("\(flag(channel.country)) \(channel.country)")
                    }
                    .font(.system(size: 9, weight: .bold))
                    .padding(8)
                    Spacer()
                    HStack(alignment: .bottom) {
                        Text(channel.name).font(.system(size: 10, weight: .bold)).lineLimit(2)
                        Spacer()
                        if allPlaybackPaused {
                            Text(localized("已暫停"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                }
            }

            if controlsVisible && isFocused {
                VStack {
                    HStack {
                        Spacer()
                        Label(
                            localized(isBeingReordered ? "調整位置" : "長按顯示更多"),
                            systemImage: isBeingReordered
                                ? "arrow.up.and.down.and.arrow.left.and.right"
                                : "ellipsis.circle.fill"
                        )
                        .font(.system(size: 8.5, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .foregroundStyle(isBeingReordered ? .black : .white)
                        .background(
                            isBeingReordered ? Color.yellow : Color.black.opacity(0.78),
                            in: Capsule()
                        )
                        Spacer()
                    }
                    Spacer()
                }
                .padding(8)
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func performPrimaryAction() {
        if longPressTriggered {
            longPressTriggered = false
            return
        }
        onActivity()
        onPrimaryAction()
    }

    #if os(iOS)
    private var iosMiniTapGesture: some Gesture {
        TapGesture(count: 2)
            .exclusively(before: TapGesture(count: 1))
            .onEnded { value in
                switch value {
                case .first:
                    performPrimaryAction()
                case .second:
                    onActivity()
                }
            }
    }
    #endif

    @ViewBuilder
    private var menuItems: some View {
        if isReorderMode {
            Button {
                onActivity()
                onFinishReorder()
            } label: {
                Label(localized("完成調整順序"), systemImage: "checkmark")
            }

            Button {
                onActivity()
                onCancelReorder()
            } label: {
                Label(localized("取消調整"), systemImage: "xmark")
            }
        } else {
            Button {
                onActivity()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    onFavorite()
                }
            } label: {
                Label(
                    localized(isFavorite ? "從我的最愛移除" : "加入我的最愛"),
                    systemImage: isFavorite ? "star.slash" : "star"
                )
            }

            Button {
                onActivity()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    onInfo()
                }
            } label: {
                Label(localized("頻道資訊"), systemImage: "info.circle")
            }

            Button {
                onActivity()
                onBeginReorder()
            } label: {
                Label(
                    localized("調整頻道位置"),
                    systemImage: "arrow.up.and.down.and.arrow.left.and.right"
                )
            }

            Divider()

            Button(role: .destructive) {
                onActivity()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    onDelete()
                }
            } label: {
                Label(localized("從播放牆移除"), systemImage: "trash")
            }
        }
    }

    private func flag(_ code: String) -> String {
        guard code.count == 2 else { return "◎" }
        return code.unicodeScalars.compactMap { UnicodeScalar(127397 + Int($0.value)).map(String.init) }.joined()
    }

}

private extension View {
    @ViewBuilder
    func platformFocusSection() -> some View {
        #if os(iOS)
        self
        #else
        self.focusSection()
        #endif
    }

    @ViewBuilder
    func platformCustomMiniFocus() -> some View {
        #if os(tvOS)
        self.focusEffectDisabled()
        #else
        self
        #endif
    }

    @ViewBuilder
    func platformHeroSafeArea() -> some View {
        #if os(macOS)
        self
        #else
        self.ignoresSafeArea()
        #endif
    }

    @ViewBuilder
    func platformPointerActivity(
        onActive: @escaping () -> Void,
        onEnded: @escaping () -> Void
    ) -> some View {
        #if os(macOS)
        self.onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active:
                onActive()
            case .ended:
                onEnded()
            }
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func platformPlainTextInput() -> some View {
        #if os(macOS)
        self.autocorrectionDisabled()
        #else
        self
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #endif
    }

    @ViewBuilder
    func platformSwitchToggleStyle() -> some View {
        #if os(macOS)
        self.toggleStyle(.switch)
        #else
        self
        #endif
    }

    @ViewBuilder
    func platformRemoteCommands(
        onMove: @escaping (WallMoveDirection) -> Void,
        onPlayPause: @escaping () -> Void,
        onExit: @escaping () -> Void
    ) -> some View {
        #if os(tvOS)
        self
            .onMoveCommand { direction in
                switch direction {
                case .left: onMove(.left)
                case .right: onMove(.right)
                case .up: onMove(.up)
                case .down: onMove(.down)
                @unknown default: break
                }
            }
            .onPlayPauseCommand(perform: onPlayPause)
            .onExitCommand(perform: onExit)
        #elseif os(macOS)
        self
            .onExitCommand(perform: onExit)
            .onKeyPress(.escape) {
                onExit()
                return .handled
            }
        #else
        self
        #endif
    }

    @ViewBuilder
    func platformReorderDrag(
        channelID: String,
        isReorderMode: Bool,
        isBeingReordered: Bool,
        onDrop: @escaping (String) -> Void
    ) -> some View {
        #if os(macOS) || os(iOS)
        if isReorderMode {
            self
                .draggable(channelID)
                .dropDestination(for: String.self) { values, _ in
                    guard let sourceID = values.first, sourceID != channelID else { return false }
                    onDrop(sourceID)
                    return true
                }
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct HeroSheetActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
            .background(configuration.isPressed ? Color.primary.opacity(0.1) : Color.clear)
    }
}
#endif

private struct TVControlButtonStyle: ButtonStyle {
    let active: Bool
    var visible = true

    func makeBody(configuration: Configuration) -> some View {
        TVControlButtonBody(configuration: configuration, active: active, visible: visible)
    }
}

private struct TVControlButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let active: Bool
    let visible: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .font(controlFont)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(visible ? (isFocused ? Color.white : active ? Color.blue.opacity(0.9) : Color.black.opacity(0.76)) : Color.clear)
            .foregroundStyle(visible ? (isFocused ? Color.black : Color.white) : Color.clear)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(visible ? (isFocused ? Color.white : Color.white.opacity(0.3)) : Color.clear, lineWidth: visible && isFocused ? 5 : 1))
            .shadow(color: visible && isFocused ? .white.opacity(0.55) : .clear, radius: 12)
            .scaleEffect(visible ? (configuration.isPressed ? pressedScale : isFocused ? focusedScale : 1) : 1)
            .animation(.easeOut(duration: 0.14), value: isFocused)
    }

    private var controlFont: Font {
        #if os(iOS) || os(macOS)
        .caption2.bold()
        #else
        .caption.bold()
        #endif
    }

    private var horizontalPadding: CGFloat {
        #if os(iOS)
        9
        #elseif os(macOS)
        10
        #else
        14
        #endif
    }

    private var verticalPadding: CGFloat {
        #if os(iOS)
        6
        #elseif os(macOS)
        7
        #else
        9
        #endif
    }

    private var focusedScale: CGFloat {
        #if os(iOS) || os(macOS)
        1.04
        #else
        1.12
        #endif
    }

    private var pressedScale: CGFloat {
        #if os(iOS) || os(macOS)
        0.97
        #else
        0.94
        #endif
    }
}

private struct AudioDuckingToggleButtonStyle: ButtonStyle {
    let enabled: Bool
    let ducking: Bool
    let controlsVisible: Bool

    func makeBody(configuration: Configuration) -> some View {
        AudioDuckingToggleButtonBody(
            configuration: configuration,
            enabled: enabled,
            ducking: ducking,
            controlsVisible: controlsVisible
        )
    }
}

private struct AudioDuckingToggleButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let enabled: Bool
    let ducking: Bool
    let controlsVisible: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(backgroundColor)
            .foregroundStyle(foregroundColor)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(strokeColor, lineWidth: isFocused ? 3 : 1))
            .shadow(color: isFocused ? .yellow.opacity(0.45) : .clear, radius: 8)
            .scaleEffect(configuration.isPressed ? pressedScale : isFocused ? focusedScale : 1)
            .animation(.easeOut(duration: 0.14), value: isFocused)
            .animation(.easeOut(duration: 0.18), value: enabled)
            .animation(.easeOut(duration: 0.18), value: ducking)
            .opacity(controlsVisible ? 1 : 0.72)
    }

    private var focusedScale: CGFloat {
        #if os(macOS)
        1.03
        #else
        1.08
        #endif
    }

    private var pressedScale: CGFloat {
        #if os(macOS)
        0.97
        #else
        0.94
        #endif
    }

    private var backgroundColor: Color {
        guard controlsVisible else { return Color.black.opacity(0.18) }
        if isFocused { return Color.yellow.opacity(0.92) }
        if ducking { return Color.orange.opacity(0.34) }
        if enabled { return Color.black.opacity(0.44) }
        return Color.black.opacity(0.22)
    }

    private var foregroundColor: Color {
        if isFocused { return .black }
        if ducking { return .orange }
        if enabled { return .white }
        return .white.opacity(0.58)
    }

    private var strokeColor: Color {
        guard controlsVisible else { return Color.white.opacity(0.14) }
        if isFocused { return .yellow }
        if ducking { return Color.orange.opacity(0.75) }
        return Color.white.opacity(enabled ? 0.28 : 0.14)
    }
}

#if os(macOS)
private struct IPTVOrgExplorerView: View {
    @ObservedObject var store: ChannelStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var country = "ALL"
    @State private var category = "ALL"
    @State private var language = "ALL"
    @State private var minimumQuality = 0
    @State private var message: String?
    @State private var selectedChannelIDs: Set<String> = []
    @State private var didStartCatalogLoad = false
    private var qualityChoices: [(String, Int)] { [
        (localized("1080p 以上"), 1080),
        (localized("720p 以上"), 720),
        (localized("576p 以上"), 576),
        (localized("480p 以上"), 480),
        (localized("270p 以上"), 270),
        (localized("所有解析度"), 0)
    ] }

    private var results: [IPTVOrgCatalogChannel] {
        store.catalogResults(search: search, country: country, categoryID: category, language: language, minimumQuality: minimumQuality)
    }

    var body: some View {
        #if os(iOS)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                explorerHeader
                explorerFilters
                explorerStatusAndCount
                if showsCatalogResults {
                    ForEach(results.prefix(250)) { channel in
                        explorerRow(channel)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .id("\(country)|\(language)|\(category)|\(minimumQuality)|\(search)")
        .background(Color.black.ignoresSafeArea())
        .onAppear { loadCatalogIfNeeded() }
        #else
        VStack(alignment: .leading, spacing: 18) {
            explorerHeader
            explorerFilters
            if store.isLoadingCatalog {
                Spacer()
                ProgressView("正在取得 iptv-org 頻道索引…")
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if let error = store.catalogError, store.catalogChannels.isEmpty {
                Spacer()
                ContentUnavailableView("無法讀取頻道索引", systemImage: "wifi.exclamationmark", description: Text(error))
                Spacer()
            } else {
                explorerMessagesAndCount
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(results.prefix(250)) { channel in
                            explorerRow(channel)
                        }
                    }
                }
                .id("\(country)|\(language)|\(category)|\(minimumQuality)|\(search)")
                .frame(maxHeight: .infinity)
            }
        }
        .padding(48)
        .background(Color.black.ignoresSafeArea())
        .onAppear { loadCatalogIfNeeded() }
        #endif
    }

    private var showsCatalogResults: Bool {
        !store.isLoadingCatalog && !(store.catalogError != nil && store.catalogChannels.isEmpty)
    }

    private func loadCatalogIfNeeded() {
        guard !didStartCatalogLoad else { return }
        didStartCatalogLoad = true
        Task { await store.loadIPTVOrgCatalog() }
    }

    @ViewBuilder
    private var explorerHeader: some View {
        #if os(iOS)
        VStack(alignment: .leading, spacing: 14) {
            explorerTitle
            HStack(spacing: 10) {
                sourceLink
                refreshButton
                Spacer(minLength: 0)
                closeButton
                addSelectedButton
            }
            .buttonStyle(.bordered)
        }
        #else
        VStack(alignment: .leading, spacing: 16) {
            explorerTitle
            HStack(spacing: 10) {
                sourceLink
                refreshButton
                Spacer(minLength: 16)
                addSelectedButton
                closeButton
            }
            .buttonStyle(.bordered)
        }
        #endif
        TextField("搜尋頻道名稱，例如 BBC、NHK", text: $search)
            .platformPlainTextInput()
            #if !os(iOS)
            .frame(maxWidth: .infinity)
            #endif
    }

    @ViewBuilder
    private var explorerFilters: some View {
        #if os(iOS)
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ],
            alignment: .leading,
            spacing: 12
        ) {
            countryFilter
            languageFilter
            categoryFilter
            qualityFilter
        }
        #else
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 16),
                GridItem(.flexible(), spacing: 16)
            ],
            alignment: .leading,
            spacing: 14
        ) {
            countryFilter
            languageFilter
            categoryFilter
            qualityFilter
        }
        .buttonStyle(.bordered)
        #endif
    }

    @ViewBuilder
    private var explorerStatusAndCount: some View {
        if store.isLoadingCatalog {
            ProgressView("正在取得 iptv-org 頻道索引…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 80)
        } else if let error = store.catalogError, store.catalogChannels.isEmpty {
            ContentUnavailableView("無法讀取頻道索引", systemImage: "wifi.exclamationmark", description: Text(error))
                .frame(maxWidth: .infinity)
        } else {
            explorerMessagesAndCount
        }
    }

    @ViewBuilder
    private var explorerMessagesAndCount: some View {
        if let message {
            Text(message).foregroundStyle(.green)
        }
        if let catalogError = store.catalogError {
            Text(catalogError).foregroundStyle(.orange)
        }
        Text("找到 \(results.count) 台可直接播放的 HLS 頻道\(results.count > 250 ? "，以下顯示前 250 台" : "")")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private func explorerRow(_ channel: IPTVOrgCatalogChannel) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(channel.name).font(.headline)
                Text("\(countryLabel(channel.country)) · \(channel.categories.map(categoryLabel).joined(separator: "、"))\(channel.languages.isEmpty ? "" : " · \(channel.languages.map(languageLabel).joined(separator: "、"))")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let quality = channel.quality { Text(quality).font(.caption).foregroundStyle(.secondary) }
            Button {
                if selectedChannelIDs.contains(channel.id) {
                    selectedChannelIDs.remove(channel.id)
                } else {
                    selectedChannelIDs.insert(channel.id)
                }
            } label: {
                Label(
                    selectionTitle(for: channel),
                    systemImage: selectionSystemImage(for: channel)
                )
            }
            .disabled(store.isCatalogChannelAdded(channel))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private var explorerTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("探索 iptv-org 頻道")
                .font(.title.bold())
            Text("依國家、語言、主題或名稱篩選；選取後加入頻道庫。")
                .foregroundStyle(.secondary)
            Text("iptv-org 是獨立的第三方社群頻道索引。IPTV Wall Player 不代管、下載或儲存影音內容。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var sourceLink: some View {
        Link(destination: URL(string: "https://github.com/iptv-org/iptv")!) {
            Label(localized("查看來源"), systemImage: "arrow.up.right.square")
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await store.loadIPTVOrgCatalog(force: true) }
        } label: {
            Label(localized("重新整理"), systemImage: "arrow.clockwise")
        }
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Label(localized("關閉"), systemImage: "xmark")
        }
    }

    private var addSelectedButton: some View {
        Button {
            addSelectedAndDismiss()
        } label: {
            Label(
                String(format: localized("加入 %lld 個頻道"), selectedChannelIDs.count),
                systemImage: "plus"
            )
        }
        .disabled(selectedChannelIDs.isEmpty)
    }

    private var countryFilter: some View {
        filterMenu(title: localized("國家"), value: country == "ALL" ? localized("所有國家") : countryLabel(country)) {
            Button("所有國家") { country = "ALL" }
            ForEach(sortedCountries, id: \.0) { code, count in
                Button("\(countryLabel(code)) · \(count)") { country = code }
            }
        }
    }

    private var languageFilter: some View {
        filterMenu(title: localized("語言"), value: language == "ALL" ? localized("所有語言") : languageLabel(language)) {
            Button("所有語言") { language = "ALL" }
            ForEach(sortedLanguages, id: \.0) { code, count in
                Button("\(languageLabel(code)) · \(count)") { language = code }
            }
        }
    }

    private var categoryFilter: some View {
        filterMenu(title: localized("主題"), value: category == "ALL" ? localized("所有主題") : categoryLabel(category)) {
            Button("所有主題") { category = "ALL" }
            ForEach(sortedCategories, id: \.0) { id, count in
                Button("\(categoryLabel(id)) · \(count)") { category = id }
            }
        }
    }

    private var qualityFilter: some View {
        filterMenu(title: localized("解析度"), value: qualityLabel) {
            ForEach(qualityChoices, id: \.1) { title, value in
                Button(title) { minimumQuality = value }
            }
        }
    }

    private func countryLabel(_ code: String) -> String {
        "\(flag(code)) \(countryName(code))"
    }

    private func countryName(_ code: String) -> String {
        Locale.autoupdatingCurrent.localizedString(forRegionCode: code) ?? code
    }

    private var sortedCountries: [(String, Int)] {
        store.catalogCountries.sorted { lhs, rhs in
            countryName(lhs.0).localizedCompare(countryName(rhs.0)) == .orderedAscending
        }
    }

    private var sortedLanguages: [(String, Int)] {
        Array(store.catalogLanguages.sorted { lhs, rhs in
            languageLabel(lhs.0).localizedCompare(languageLabel(rhs.0)) == .orderedAscending
        }.prefix(80))
    }

    private var sortedCategories: [(String, Int)] {
        store.catalogCategories.sorted { lhs, rhs in
            categoryLabel(lhs.0).localizedCompare(categoryLabel(rhs.0)) == .orderedAscending
        }
    }

    private var qualityLabel: String {
        qualityChoices.first(where: { $0.1 == minimumQuality })?.0 ?? localized("所有解析度")
    }

    private func filterMenu<Content: View>(title: String, value: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            Menu(content: content) {
                HStack(spacing: 8) {
                    Text(value)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 128, maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectionTitle(for channel: IPTVOrgCatalogChannel) -> String {
        if store.isCatalogChannelAdded(channel) { return localized("已加入播放清單") }
        return localized(selectedChannelIDs.contains(channel.id) ? "已選取" : "選取")
    }

    private func selectionSystemImage(for channel: IPTVOrgCatalogChannel) -> String {
        if store.isCatalogChannelAdded(channel) { return "checkmark.circle.fill" }
        return selectedChannelIDs.contains(channel.id) ? "checkmark.circle.fill" : "plus.circle"
    }

    private func addSelectedAndDismiss() {
        let selectedChannels = results.filter { selectedChannelIDs.contains($0.id) }
        guard !selectedChannels.isEmpty else { return }
        do {
            for channel in selectedChannels where !store.isCatalogChannelAdded(channel) {
                try store.addCatalogChannel(channel)
            }
            message = "已將 \(selectedChannels.count) 台頻道加入頻道庫。"
            dismiss()
        } catch {
            message = "無法儲存 M3U：\(error.localizedDescription)"
        }
    }

    private func flag(_ code: String) -> String {
        guard code.count == 2 else { return "◎" }
        return code.unicodeScalars.compactMap { UnicodeScalar(127397 + Int($0.value)).map(String.init) }.joined()
    }

    private func categoryLabel(_ id: String) -> String {
        guard let key = ["news": "新聞", "business": "財經", "sports": "體育", "general": "綜合", "entertainment": "娛樂", "movies": "電影", "music": "音樂", "kids": "兒童", "education": "教育", "documentary": "紀錄片", "culture": "文化", "religious": "宗教", "government": "政府", "weather": "氣象" ][id] else {
            return id
        }
        return localized(key)
    }

    private func languageLabel(_ code: String) -> String {
        ["eng": "English", "zho": "中文", "jpn": "日本語", "kor": "한국어", "spa": "Español", "fra": "Français", "deu": "Deutsch", "ita": "Italiano", "por": "Português", "rus": "Русский", "ara": "العربية", "hin": "हिन्दी" ][code] ?? code.uppercased()
    }
}
#endif

private enum M3UManagerConfirmation: String, Identifiable {
    case clearPlaylists
#if os(macOS)
    case clearCloud
    case restoreCloud
#endif

    var id: String { rawValue }
}

private enum LibrarySourceFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case iptv = "IPTV"
    case go2rtc = "go2rtc"

    var id: String { rawValue }
}

#if os(macOS)
private struct CloudLibraryBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
#endif

private struct M3UManagerView: View {
    @ObservedObject var store: ChannelStore
    #if os(macOS)
    let onExplore: () -> Void
    #endif
    @Environment(\.dismiss) private var dismiss
    @State private var sourceURL = ""
    @State private var remoteURL = ""
    @State private var remoteEnabled = false
    @State private var remoteIntervalMinutes = 10
    @State private var message = platformM3UImportHint()
    @State private var messageIsError = false
    @State private var pendingConfirmation: M3UManagerConfirmation?
    @State private var showPrivacy = false
    @State private var librarySourceFilter: LibrarySourceFilter = .all
#if os(macOS)
    @State private var cloudOperationInProgress = false
    @State private var showGo2RTCResults = false
    @State private var cloudBackupDocument: CloudLibraryBackupDocument?
    @State private var cloudBackupFilename = "IPTVWall-iCloud-backup.json"
    @State private var cloudBackupExporterPresented = false
    @State private var cloudBackupImporterPresented = false
    @State private var pendingCloudRestoreBackup: CloudLibraryBackup?
#endif
    private let intervalChoices = [5, 10, 15, 30, 60, 120]

    private var libraryChannels: [NewsChannel] {
        store.channels.filter { channel in
            guard !store.unavailable.contains(channel.id) else { return false }
            guard !store.deletedChannelIDs.contains(channel.id) else { return false }
            switch librarySourceFilter {
            case .all: return true
            case .iptv: return channel.category == .m3u
            case .go2rtc: return channel.category == .go2rtc
            }
        }
        .sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func sourceBadgeText(for channel: NewsChannel) -> String {
        channel.category == .go2rtc ? "go2rtc" : "IPTV"
    }

    private func sourceBadgeColor(for channel: NewsChannel) -> Color {
        channel.category == .go2rtc ? Color.blue : Color.green
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("頻道庫")
                        .font(.title.bold())
                    Text("新增頻道、管理來源與同步")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("隱私權") { showPrivacy = true }
                Button("完成") { dismiss() }
            }

            Text(message)
                .font(.callout)
                .foregroundStyle(messageIsError ? Color.red : Color.secondary)

            VStack(alignment: .leading, spacing: 12) {
                Text("新增頻道")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 10) {
                    TextField("https://example.com/playlist.m3u", text: $sourceURL)
                        .platformPlainTextInput()

                    HStack(spacing: 10) {
                        Button(localized(store.isImportingM3U ? "加入中…" : "加入 M3U")) {
                            importPlaylist()
                        }
                        .disabled(store.isImportingM3U || sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        #if os(macOS)
                        Button("探索公開頻道") { onExplore() }
                        Button(store.isScanningGo2RTC ? "掃描中…" : "掃描 go2rtc 攝影機") {
                            scanGo2RTC()
                        }
                        .disabled(store.isScanningGo2RTC)
                        #endif
                    }
                }

                #if os(macOS)
                if store.isScanningGo2RTC {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(go2rtcScanStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                #endif

                #if !os(macOS)
                Text("貼上你有權使用的 M3U 播放清單網址。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #else
                Text("貼上自己的 M3U 網址，或從獨立的 iptv-org 社群索引挑選公開頻道。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

            HStack {
                Text("已匯入播放清單（\(store.importedPlaylists.count)）")
                    .font(.headline)
                Spacer()
                Button("全部清空", role: .destructive) {
                    pendingConfirmation = .clearPlaylists
                }
                    .disabled(store.importedPlaylists.isEmpty)
            }

            if store.importedPlaylists.isEmpty {
                Text("目前沒有已匯入的播放清單")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(store.importedPlaylists) { playlist in
                        HStack(spacing: 18) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(playlist.name).font(.headline)
                                Text("\(playlist.channelCount) 個頻道 · \(playlist.sourceURL)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button("刪除", role: .destructive) {
                                do {
                                    try store.removeImportedPlaylist(playlist)
                                    message = "已刪除「\(playlist.name)」。"
                                    messageIsError = false
                                } catch {
                                    showError(error)
                                }
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("頻道列表（(libraryChannels.count)）")
                        .font(.headline)
                    Spacer()
                    Picker("來源", selection: $librarySourceFilter) {
                        ForEach(LibrarySourceFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                }

                if libraryChannels.isEmpty {
                    Text("沒有符合這個來源的頻道")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(libraryChannels) { channel in
                            HStack(spacing: 14) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(channel.name)
                                        .font(.headline)
                                        .lineLimit(2)
                                    Text(channel.url.absoluteString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Text(sourceBadgeText(for: channel))
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(sourceBadgeColor(for: channel).opacity(0.2), in: Capsule())
                                Button(role: .destructive) {
                                    store.deleteChannel(channel)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("iCloud 自動同步")
                            .font(.headline)
                        Text("在使用相同 iCloud 帳號的 Apple TV、Mac、iPhone 與 iPad 之間自動同步頻道庫、排序、我的最愛及刪除狀態。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(
                        localized("自動同步"),
                        isOn: Binding(
                            get: { store.isCloudLibrarySyncEnabled },
                            set: { store.setCloudLibrarySyncEnabled($0) }
                        )
                    )
                    .platformSwitchToggleStyle()
                    .fixedSize()

                    Menu {
                        Button {
                            Task { await store.syncCloudLibraryIfNeeded(force: true) }
                        } label: {
                            Label(localized("立即同步"), systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(!store.isCloudLibrarySyncEnabled || store.isSyncingCloudLibrary)
                    } label: {
                        Label(localized("同步選項"), systemImage: "ellipsis.circle")
                            .labelStyle(.iconOnly)
                    }
                }

                Label(cloudLibraryStatusText, systemImage: cloudLibraryStatusSystemImage)
                    .font(.caption)
                    .foregroundStyle(store.cloudLibraryError == nil ? Color.secondary : Color.orange)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

#if os(macOS)
            cloudLibraryTools
#endif

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("遠端 M3U 同步")
                            .font(.headline)
                        Text("固定讀取指定 M3U URL，並依設定的時間間隔檢查更新。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(localized("遠端同步"), isOn: $remoteEnabled)
                        .platformSwitchToggleStyle()
                        .fixedSize()
                }

                VStack(alignment: .leading, spacing: 10) {
                    TextField("https://example.com/remote-playlist.m3u", text: $remoteURL)
                        .platformPlainTextInput()

                    HStack(spacing: 10) {
                        Menu {
                            ForEach(intervalChoices, id: \.self) { minutes in
                                Button("\(minutes) 分鐘") { remoteIntervalMinutes = minutes }
                            }
                        } label: {
                            Text("每 \(remoteIntervalMinutes) 分鐘重載")
                        }

                        Button("儲存") {
                            saveRemoteSyncSettings()
                        }

                        Button(localized(store.isSyncingRemoteM3U ? "同步中…" : "立即同步")) {
                            saveRemoteSyncSettings(syncNow: true)
                        }
                        .disabled(store.isSyncingRemoteM3U || remoteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Text(remoteStatusText)
                    .font(.caption)
                    .foregroundStyle(store.remoteSyncSettings.lastError == nil ? Color.secondary : Color.orange)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(48)
        }
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: $showPrivacy) {
            PrivacyPolicyView()
        }
#if os(macOS)
        .sheet(isPresented: $showGo2RTCResults) {
            Go2RTCScanResultView(store: store) { count in
                message = "已加入 \(count) 個 go2rtc 攝影機。"
                messageIsError = false
            }
        }
#endif
        .onAppear {
            let settings = store.remoteSyncSettings
            remoteURL = settings.sourceURL
            remoteEnabled = settings.isEnabled
            remoteIntervalMinutes = settings.reloadIntervalMinutes
        }
        .alert(item: $pendingConfirmation) { confirmation in
            confirmationAlert(for: confirmation)
        }
#if os(macOS)
        .fileExporter(
            isPresented: $cloudBackupExporterPresented,
            document: cloudBackupDocument,
            contentType: .json,
            defaultFilename: cloudBackupFilename
        ) { result in
            handleCloudBackupExport(result)
        }
        .fileImporter(
            isPresented: $cloudBackupImporterPresented,
            allowedContentTypes: [.json]
        ) { result in
            handleCloudRestoreSelection(result)
        }
#endif
    }

    private func confirmationAlert(for confirmation: M3UManagerConfirmation) -> Alert {
        switch confirmation {
        case .clearPlaylists:
            return Alert(
                title: Text("清空所有 M3U 播放清單？"),
                message: Text("此動作會移除這台裝置及 iCloud 同步資料中的所有播放清單。"),
                primaryButton: .cancel(Text("保留")),
                secondaryButton: .destructive(Text("全部清空")) {
                    do {
                        try store.clearImportedPlaylists()
                        message = "已清空所有 M3U 播放清單。"
                        messageIsError = false
                    } catch {
                        showError(error)
                    }
                }
            )
#if os(macOS)
        case .clearCloud:
            return Alert(
                title: Text("清空 iCloud 測試資料？"),
                message: Text("這會把 CloudKit 播放牆與 iCloud 收藏重設為空白。其他裝置下次同步時會清除舊頻道；這台 Mac 的本機播放清單會保留，但自動同步會暫停。"),
                primaryButton: .cancel(Text("取消")),
                secondaryButton: .destructive(Text("清空 iCloud")) {
                    clearCloudLibrary()
                }
            )
        case .restoreCloud:
            return Alert(
                title: Text("回存 iCloud 測試資料？"),
                message: Text("這會覆寫目前 iCloud 中的 IPTV Wall 設定與收藏資料。"),
                primaryButton: .cancel(Text("取消")) {
                    pendingCloudRestoreBackup = nil
                },
                secondaryButton: .destructive(Text("回存")) {
                    guard let backup = pendingCloudRestoreBackup else { return }
                    pendingCloudRestoreBackup = nil
                    restoreCloudLibrary(backup)
                }
            )
#endif
        }
    }

    private func importPlaylist() {
        Task {
            do {
                let count = try await store.importM3U(from: sourceURL)
                message = "匯入成功，共加入 \(count) 個頻道。"
                messageIsError = false
                sourceURL = ""
                store.selectCategory(.all)
            } catch {
                showError(error)
            }
        }
    }

#if os(macOS)
    private func scanGo2RTC() {
        guard !store.isScanningGo2RTC else { return }
        Task {
            let candidates = await store.discoverGo2RTCChannels()
            if candidates.isEmpty {
                message = "在區域網路中沒有找到新的 go2rtc 攝影機。"
                messageIsError = false
            } else {
                showGo2RTCResults = true
            }
        }
    }

    private var go2rtcScanStatusText: String {
        guard let status = store.go2rtcScanStatus else { return "正在掃描區域網路…" }
        switch status.stage {
        case .discovering:
            return "正在尋找 go2rtc 主機（\(status.scannedHosts)/\(status.totalHosts)），找到 \(status.foundServers) 台"
        case .verifying:
            return "正在確認攝影機畫面（\(status.verifiedStreams) 個）"
        }
    }
#endif

    private var remoteStatusText: String {
        let settings = store.remoteSyncSettings
        var parts: [String] = []
        if settings.isEnabled {
            parts.append("已啟用")
        } else {
            parts.append("未啟用")
        }
        if let lastCheckedAt = settings.lastCheckedAt {
            parts.append("上次檢查 \(lastCheckedAt.formatted(date: .omitted, time: .shortened))")
        }
        if let lastUpdatedAt = settings.lastUpdatedAt {
            parts.append("上次更新 \(lastUpdatedAt.formatted(date: .omitted, time: .shortened))")
        }
        if let error = settings.lastError, !error.isEmpty {
            parts.append("錯誤：\(error)")
        }
        return parts.joined(separator: " · ")
    }

    private var cloudLibraryStatusText: String {
        if !store.isCloudLibrarySyncEnabled {
            return "已停用；播放清單只保存在這台裝置。"
        }
        if store.isSyncingCloudLibrary {
            return "正在與 iCloud 同步播放清單…"
        }
        if let error = store.cloudLibraryError, !error.isEmpty {
            return "同步尚未完成：\(error)"
        }
        if let lastSyncedAt = store.cloudLibraryLastSyncedAt {
            return "上次同步 \(lastSyncedAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return "等待第一次同步。"
    }

    private var cloudLibraryStatusSystemImage: String {
        if !store.isCloudLibrarySyncEnabled { return "icloud.slash" }
        if store.isSyncingCloudLibrary { return "arrow.triangle.2.circlepath" }
        if store.cloudLibraryError != nil { return "exclamationmark.icloud" }
        if store.cloudLibraryLastSyncedAt != nil { return "checkmark.icloud" }
        return "icloud"
    }

#if os(macOS)
    private var cloudLibraryTools: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("iCloud 測試資料")
                    .font(.headline)
                Text("備份、回存或重設這個 Apple ID 的 IPTV Wall 設定。重設後，其他裝置會同步收到空白頻道庫；這台 Mac 會暫停自動同步。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    backupCloudLibrary()
                } label: {
                    Label("備份", systemImage: "arrow.down.doc")
                }
                .disabled(cloudOperationInProgress || store.isSyncingCloudLibrary)

                Button {
                    chooseCloudRestoreFile()
                } label: {
                    Label("回存", systemImage: "arrow.up.doc")
                }
                .disabled(cloudOperationInProgress || store.isSyncingCloudLibrary)

                Button(role: .destructive) {
                    pendingConfirmation = .clearCloud
                } label: {
                    Label("清空 iCloud", systemImage: "trash")
                }
                .disabled(cloudOperationInProgress || store.isSyncingCloudLibrary)

                if cloudOperationInProgress {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
    }
#endif

    private func saveRemoteSyncSettings(syncNow: Bool = false) {
        var settings = store.remoteSyncSettings
        settings.isEnabled = remoteEnabled
        settings.sourceURL = remoteURL
        settings.reloadIntervalMinutes = remoteIntervalMinutes
        if !remoteEnabled {
            settings.lastError = nil
        }
        store.saveRemoteSyncSettings(settings)
        message = remoteEnabled ? "遠端 M3U 同步設定已儲存。" : "遠端 M3U 同步已停用。"
        messageIsError = false

        guard syncNow else { return }
        Task {
            await store.syncRemotePlaylist(force: true)
            if let error = store.remoteSyncSettings.lastError {
                message = error
                messageIsError = true
            } else {
                message = "遠端 M3U 已同步完成。"
                messageIsError = false
            }
        }
    }

#if os(macOS)
    private func backupCloudLibrary() {
        cloudOperationInProgress = true
        Task {
            do {
                let backup = try await store.makeCloudLibraryBackup()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                cloudBackupDocument = CloudLibraryBackupDocument(data: try encoder.encode(backup))
                cloudBackupFilename = "IPTVWall-iCloud-backup-\(Int(Date().timeIntervalSince1970)).json"
                cloudBackupExporterPresented = true
            } catch {
                showError(error)
            }
            cloudOperationInProgress = false
        }
    }

    private func chooseCloudRestoreFile() {
        cloudBackupImporterPresented = true
    }

    private func handleCloudBackupExport(_ result: Result<URL, Error>) {
        defer { cloudBackupDocument = nil }
        switch result {
        case .success(let url):
            message = "iCloud 設定已備份至「\(url.lastPathComponent)」。"
            messageIsError = false
        case .failure(let error):
            let cocoaError = error as NSError
            guard cocoaError.domain != NSCocoaErrorDomain || cocoaError.code != NSUserCancelledError else { return }
            showError(error)
        }
    }

    private func handleCloudRestoreSelection(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let isAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if isAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            pendingCloudRestoreBackup = try JSONDecoder().decode(
                CloudLibraryBackup.self,
                from: Data(contentsOf: url)
            )
            pendingConfirmation = .restoreCloud
        } catch {
            let cocoaError = error as NSError
            guard cocoaError.domain != NSCocoaErrorDomain || cocoaError.code != NSUserCancelledError else { return }
            showError(error)
        }
    }

    private func restoreCloudLibrary(_ backup: CloudLibraryBackup) {
        cloudOperationInProgress = true
        Task {
            do {
                try await store.restoreCloudLibraryBackup(backup)
                message = "iCloud 設定已回存。"
                messageIsError = false
            } catch {
                showError(error)
            }
            cloudOperationInProgress = false
        }
    }

    private func clearCloudLibrary() {
        cloudOperationInProgress = true
        Task {
            do {
                try await store.clearCloudLibraryForTesting()
                message = "iCloud 已寫入空白重置狀態；其他裝置下次同步會清除舊頻道，本機自動同步已暫停。"
                messageIsError = false
            } catch {
                showError(error)
            }
            cloudOperationInProgress = false
        }
    }
#endif

    private func showError(_ error: Error) {
        message = error.localizedDescription
        messageIsError = true
    }
}

#if os(macOS)
private struct Go2RTCScanResultView: View {
    @ObservedObject var store: ChannelStore
    let onAdded: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []

    private var candidates: [Go2RTCDiscovery.Candidate] {
        store.go2rtcScanCandidates
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("go2rtc 掃描結果")
                    .font(.title.bold())
                Text("勾選要加入播放牆的攝影機。已確認有畫面的會預先勾選。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if candidates.isEmpty {
                Text("沒有找到攝影機。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(candidates) { candidate in
                            Toggle(isOn: selectionBinding(for: candidate.id)) {
                                HStack(spacing: 10) {
                                    Image(systemName: candidate.succeeded ? "checkmark.circle.fill" : "xmark.circle")
                                        .foregroundStyle(candidate.succeeded ? Color.green : Color.orange)
                                    Text(candidate.name)
                                    if let reason = candidate.failureReason {
                                        Text(reason)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("加入播放牆") {
                    let chosen = candidates.filter { selection.contains($0.id) }
                    let count = store.addSelectedGo2RTCChannels(chosen)
                    onAdded(count)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty)
            }
        }
        .padding(28)
        .frame(minWidth: 460, minHeight: 360)
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            let existing = Set(store.go2rtcChannels.map(\.id))
            selection = Set(candidates.filter { $0.succeeded || existing.contains($0.id) }.map(\.id))
        }
    }

    private func selectionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { selection.contains(id) },
            set: { checked in
                if checked { selection.insert(id) } else { selection.remove(id) }
            }
        )
    }
}
#endif

private struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss
    private let policyURL = URL(string: "https://global-news-wall.giving-pond-5984.chatgpt.site/privacy")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("隱私權")
                        .font(.title.bold())
                    Spacer()
                    Button("完成") { dismiss() }
                }

                Group {
                    privacySection(
                        title: localized("我們不追蹤你"),
                        text: localized("IPTV Wall Player 不含廣告追蹤、第三方分析工具，也不建立使用者帳號。")
                    )
                    privacySection(
                        title: localized("播放清單與 iCloud"),
                        text: localized("你匯入的 M3U 內容、網址、我的最愛、排序與遠端同步設定會保存在裝置上。開啟 iCloud 同步時，這些資料會存入你的私人 CloudKit 資料庫，供同一 Apple Account 的裝置使用。")
                    )
                    privacySection(
                        title: localized("macOS 自動靜音"),
                        text: localized("自動靜音只在 Mac 本機判斷其他 App 是否正在輸出音訊；判斷結果不會保存或傳送。")
                    )
                    privacySection(
                        title: localized("你的控制權"),
                        text: localized("你可以停用 iCloud 同步、刪除播放清單，或在 iCloud 設定中撤銷 App 的 iCloud 存取權。")
                    )
                    privacySection(
                        title: localized("使用授權"),
                        text: localized("個人使用免費。機構、商業場所、公共展示或收費服務用途，須先取得 IPTV Wall Player 商業授權。IPTV Wall Player 不提供或代管第三方影音內容，你必須對匯入的播放清單與串流網址擁有合法使用權。")
                    )
                }

                Link(destination: policyURL) {
                    Label(localized("閱讀完整隱私權政策"), systemImage: "arrow.up.right.square")
                }
                Text(policyURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(48)
        }
        .background(Color.black.ignoresSafeArea())
    }

    private func privacySection(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
