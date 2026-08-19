import Foundation
import Darwin

struct Go2RTCDiscovery {
    private static let apiPort = 1984

    struct Candidate: Identifiable {
        let id: String
        let name: String
        let channel: NewsChannel?
        let failureReason: String?

        var succeeded: Bool { channel != nil && failureReason == nil }
    }

    struct Progress {
        let phase: Phase
        let scannedHosts: Int
        let totalHosts: Int
        let foundServers: Int
        let verifiedStreams: Int
    }

    enum Phase {
        case discovering
        case verifying
    }

    static func discover(onProgress: ((Progress) -> Void)? = nil) async -> [Candidate] {
        if ProcessInfo.processInfo.arguments.contains("--seed-favorites-for-ui-testing") { return [] }
        let hosts = localIPv4Hosts()
        guard !hosts.isEmpty else { return [] }

        var servers: [(String, [String])] = []
        var scannedHosts = 0
        for batch in hosts.chunked(into: 32) {
            let found = await withTaskGroup(of: (String, [String])?.self) { group in
                for host in batch {
                    group.addTask {
                        guard let names = await streamNames(on: host), !names.isEmpty else { return nil }
                        return (host, names)
                    }
                }
                var results: [(String, [String])] = []
                for await result in group { if let result { results.append(result) } }
                return results
            }
            servers.append(contentsOf: found)
            scannedHosts += batch.count
            onProgress?(Progress(phase: .discovering, scannedHosts: scannedHosts, totalHosts: hosts.count, foundServers: servers.count, verifiedStreams: 0))
        }

        var preferredCandidates: [(host: String, stream: String, playbackStream: String)] = []
        for server in servers {
            let names = Set(server.1)
            for stream in server.1 where !stream.hasSuffix("_h264") {
                let playbackStream = names.contains("\(stream)_h264") ? "\(stream)_h264" : stream
                preferredCandidates.append((host: server.0, stream: stream, playbackStream: playbackStream))
            }
        }
        var scanResults: [Candidate] = []
        var verifiedStreams = 0

        // Starting too many camera producers at once can overwhelm go2rtc and
        // causes slow RTSP cameras to be incorrectly treated as unavailable.
        for batch in preferredCandidates.chunked(into: 4) {
            let verified = await withTaskGroup(of: Candidate.self) { group in
                for item in batch {
                    group.addTask {
                        let snapshotURL = endpoint(
                            host: item.host,
                            path: "/api/frame.jpeg",
                            queryItems: [URLQueryItem(name: "src", value: item.playbackStream)]
                        )
                        let streamURL = endpoint(
                            host: item.host,
                            path: "/api/stream.m3u8",
                            queryItems: [
                                URLQueryItem(name: "src", value: item.playbackStream),
                                URLQueryItem(name: "mp4", value: nil)
                            ]
                        )

                        let id = "go2rtc:\(item.host):\(item.stream)"
                        if let streamURL {
                            let channel = NewsChannel(
                                id: id,
                                name: item.stream,
                                url: streamURL,
                                logoURL: snapshotURL,
                                country: "LAN",
                                category: .go2rtc
                            )
                            let videoOK: Bool
                            if let snapshotURL {
                                videoOK = await hasVideo(at: snapshotURL)
                            } else {
                                videoOK = false
                            }
                            return Candidate(
                                id: id,
                                name: item.stream,
                                channel: channel,
                                failureReason: videoOK ? nil : "找不到影像畫面"
                            )
                        }
                        return Candidate(
                            id: id,
                            name: item.stream,
                            channel: nil,
                            failureReason: "無法建立串流"
                        )
                    }
                }
                var results: [Candidate] = []
                for await item in group { results.append(item) }
                return results
            }
            scanResults.append(contentsOf: verified)
            verifiedStreams = scanResults.filter { $0.succeeded }.count
            onProgress?(Progress(phase: .verifying, scannedHosts: scannedHosts, totalHosts: hosts.count, foundServers: servers.count, verifiedStreams: verifiedStreams))
        }

        return scanResults.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func streamNames(on host: String) async -> [String]? {
        guard let url = endpoint(host: host, path: "/api/streams") else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        do {
            let (data, response) = try await URLSession(configuration: configuration).data(from: url)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return object.keys.sorted()
        } catch { return nil }
    }

    private static func hasVideo(at url: URL) async -> Bool {
        for attempt in 0..<2 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 6
            configuration.timeoutIntervalForResource = 8
            do {
                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                let (data, response) = try await URLSession(configuration: configuration).data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { continue }
                let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                if !data.isEmpty && (contentType.hasPrefix("image/") || data.starts(with: [0xFF, 0xD8])) {
                    return true
                }
            } catch {
                continue
            }
        }
        return false
    }

    private static func endpoint(host: String, path: String, queryItems: [URLQueryItem] = []) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = apiPort
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url
    }

    private static func localIPv4Hosts() -> [String] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }

        var hosts = Set<UInt32>()
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let interface = current.pointee
            pointer = interface.ifa_next
            guard let addressPointer = interface.ifa_addr,
                  addressPointer.pointee.sa_family == UInt8(AF_INET),
                  let netmaskPointer = interface.ifa_netmask else { continue }

            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }

            let address = addressPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let mask = netmaskPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let network = address & mask
            let broadcast = network | ~mask
            let usableCount = broadcast > network ? broadcast - network - 1 : 0

            if usableCount > 0, usableCount <= 254 {
                for candidate in (network + 1)..<broadcast where candidate != address { hosts.insert(candidate) }
            } else {
                let localNetwork = address & 0xFFFFFF00
                for suffix in UInt32(1)...254 {
                    let candidate = localNetwork | suffix
                    if candidate != address { hosts.insert(candidate) }
                }
            }
        }
        return hosts.sorted().map(ipv4String)
    }

    private static func ipv4String(_ value: UInt32) -> String {
        "\((value >> 24) & 0xFF).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
