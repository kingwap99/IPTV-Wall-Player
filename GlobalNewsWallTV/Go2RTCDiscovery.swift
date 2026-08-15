import Foundation
import Darwin

struct Go2RTCDiscovery {
    private static let apiPort = 1984

    static func discover() async -> [NewsChannel] {
        if ProcessInfo.processInfo.arguments.contains("--seed-favorites-for-ui-testing") { return [] }
        let hosts = localIPv4Hosts()
        guard !hosts.isEmpty else { return [] }

        var servers: [(String, [String])] = []
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
        }

        let candidates = servers.flatMap { server in
            server.1.map { (host: server.0, stream: $0) }
        }
        var channels: [NewsChannel] = []

        // Starting too many camera producers at once can overwhelm go2rtc and
        // causes slow RTSP cameras to be incorrectly treated as unavailable.
        for batch in candidates.chunked(into: 4) {
            let verified = await withTaskGroup(of: NewsChannel?.self) { group in
                for candidate in batch {
                    group.addTask {
                        guard let snapshotURL = endpoint(
                            host: candidate.host,
                            path: "/api/frame.jpeg",
                            queryItems: [URLQueryItem(name: "src", value: candidate.stream)]
                        ), await hasVideo(at: snapshotURL),
                        let streamURL = endpoint(
                            host: candidate.host,
                            path: "/api/stream.m3u8",
                            queryItems: [
                                URLQueryItem(name: "src", value: candidate.stream),
                                URLQueryItem(name: "mp4", value: nil)
                            ]
                        ) else { return nil }

                        return NewsChannel(
                            id: "go2rtc:\(candidate.host):\(candidate.stream)",
                            name: candidate.stream,
                            url: streamURL,
                            logoURL: snapshotURL,
                            country: "LAN",
                            category: .go2rtc
                        )
                    }
                }
                var valid: [NewsChannel] = []
                for await channel in group { if let channel { valid.append(channel) } }
                return valid
            }
            channels.append(contentsOf: verified)
        }

        return channels.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func streamNames(on host: String) async -> [String]? {
        guard let url = endpoint(host: host, path: "/api/streams") else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.5
        configuration.timeoutIntervalForResource = 2.5
        do {
            let (data, response) = try await URLSession(configuration: configuration).data(from: url)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return object.keys.sorted()
        } catch { return nil }
    }

    private static func hasVideo(at url: URL) async -> Bool {
        for attempt in 0..<3 {
            if attempt > 0 {
                let delay = UInt64(attempt * 2) * 1_000_000_000
                try? await Task.sleep(nanoseconds: delay)
            }

            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 10
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
