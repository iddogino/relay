import Darwin
import Foundation

/// Names other devices could reach this Mac by, best first: its tailnet
/// name (Tailscale's MagicDNS) or tailnet address, then its Bonjour
/// `.local` name, then LAN addresses. Read from the network interfaces and
/// DNS only — no `tailscale` command — so it works in the App Sandbox.
public enum LocalNetworkAddresses {
    public struct Candidate: Sendable, Hashable, Identifiable {
        public enum Kind: String, Sendable, Hashable {
            /// MagicDNS name, e.g. `mac.tailnet-1234.ts.net`.
            case tailnetName
            /// A Tailscale address (100.64.0.0/10 or fd7a:115c:a1e0::/48).
            case tailnetAddress
            /// Bonjour, e.g. `Mac-mini.local`: same network only.
            case bonjour
            /// A LAN address: same network only, and may change.
            case lanAddress
        }

        public let address: String
        public let kind: Kind
        public var id: String { address }

        public init(address: String, kind: Kind) {
            self.address = address
            self.kind = kind
        }

        public var caption: String {
            switch kind {
            case .tailnetName: return "Tailscale name: reachable from anywhere on your tailnet"
            case .tailnetAddress: return "Tailscale address: reachable from anywhere on your tailnet"
            case .bonjour: return "Bonjour name: reachable on the same network only"
            case .lanAddress: return "Local network address: same network only, and it may change"
            }
        }
    }

    /// All candidates, best first. Does a reverse DNS lookup per tailnet
    /// address (fast: Tailscale answers it locally), so call it off the
    /// main thread.
    public static func candidates(localHostName: String?) -> [Candidate] {
        var result: [Candidate] = []
        let addresses = interfaceAddresses()
        let tailnet = addresses.filter { isTailnet($0.address) }
        // IPv4 first: the shorter, more familiar address.
        // Asked of Tailscale's own resolver: the system one can take many
        // seconds for a reverse lookup, or not get an answer in the sandbox.
        for entry in tailnet where !entry.address.contains(":") {
            if let name = MagicDNS.reverseLookup(ipv4: entry.address), name.hasSuffix(".ts.net"),
               !result.contains(where: { $0.address == name }) {
                result.append(Candidate(address: name, kind: .tailnetName))
            }
        }
        for entry in tailnet where !entry.address.contains(":") {
            result.append(Candidate(address: entry.address, kind: .tailnetAddress))
        }
        if let localHostName, !localHostName.isEmpty {
            result.append(Candidate(address: "\(localHostName).local", kind: .bonjour))
        }
        for entry in addresses where isLAN(entry.address) {
            result.append(Candidate(address: entry.address, kind: .lanAddress))
        }
        return result
    }

    struct InterfaceAddress: Hashable {
        let interface: String
        let address: String
    }

    static func interfaceAddresses() -> [InterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [InterfaceAddress] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let sockaddr = entry.ifa_addr,
                  (entry.ifa_flags & UInt32(IFF_UP)) != 0,
                  (entry.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let family = Int32(sockaddr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(sockaddr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            let interface = String(cString: entry.ifa_name)
            let candidate = InterfaceAddress(interface: interface, address: address)
            if !result.contains(candidate) { result.append(candidate) }
        }
        return result
    }

    /// Tailscale's ranges: CGNAT 100.64.0.0/10 and fd7a:115c:a1e0::/48.
    /// Pure; unit-tested.
    public static func isTailnet(_ address: String) -> Bool {
        if address.contains(":") {
            return address.lowercased().hasPrefix("fd7a:115c:a1e0:")
        }
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 100 && (octets[1] & 0xC0) == 64
    }

    /// Private IPv4 LAN ranges (10/8, 172.16/12, 192.168/16). Pure.
    public static func isLAN(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _): return true
        case (172, 16...31): return true
        case (192, 168): return true
        default: return false
        }
    }
}

/// Reverse lookups asked straight of Tailscale's MagicDNS resolver
/// (100.100.100.100), which answers for tailnet addresses at once.
public enum MagicDNS {
    static let resolver = "100.100.100.100"

    static func reverseLookup(ipv4: String, timeout: Duration = .milliseconds(1500)) -> String? {
        let octets = ipv4.split(separator: ".")
        guard octets.count == 4 else { return nil }
        let query = ptrQuery(name: octets.reversed().joined(separator: ".") + ".in-addr.arpa", id: UInt16.random(in: 1...UInt16.max))
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(53).bigEndian
        address.sin_addr.s_addr = inet_addr(resolver)
        // Connected, so the reply is part of an outgoing exchange: the App
        // Sandbox (network.client only) refuses replies to an unconnected
        // socket.
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        let sent = query.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == query.count else { return nil }
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let milliseconds = Int32(timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000)
        guard poll(&poller, 1, milliseconds) == 1 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 1500)
        let count = recv(fd, &buffer, buffer.count, 0)
        guard count > 12 else { return nil }
        return parsePTRAnswer(Array(buffer[0..<count]), id: query.prefix(2))
    }

    /// A DNS query for `name`'s PTR record. Pure; unit-tested.
    static func ptrQuery(name: String, id: UInt16) -> [UInt8] {
        var bytes: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") {
            let utf8 = Array(label.utf8)
            bytes.append(UInt8(utf8.count))
            bytes += utf8
        }
        bytes += [0, 0, 12, 0, 1]
        return bytes
    }

    /// The first PTR answer's name in a DNS response. Pure; unit-tested.
    static func parsePTRAnswer<ID: Collection>(_ message: [UInt8], id: ID) -> String? where ID.Element == UInt8 {
        guard message.count > 12, message.prefix(2).elementsEqual(id), message[3] & 0x0F == 0 else { return nil }
        let questions = Int(message[4]) << 8 | Int(message[5])
        let answers = Int(message[6]) << 8 | Int(message[7])
        var offset = 12
        for _ in 0..<questions {
            guard skipName(message, &offset) else { return nil }
            offset += 4
        }
        for _ in 0..<answers {
            guard skipName(message, &offset), offset + 10 <= message.count else { return nil }
            let type = Int(message[offset]) << 8 | Int(message[offset + 1])
            let length = Int(message[offset + 8]) << 8 | Int(message[offset + 9])
            offset += 10
            if type == 12 {
                var at = offset
                return readName(message, &at).map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
            }
            offset += length
        }
        return nil
    }

    private static func skipName(_ message: [UInt8], _ offset: inout Int) -> Bool {
        while offset < message.count {
            let length = message[offset]
            if length & 0xC0 == 0xC0 { offset += 2; return offset <= message.count }
            offset += 1
            if length == 0 { return true }
            offset += Int(length)
        }
        return false
    }

    private static func readName(_ message: [UInt8], _ offset: inout Int, depth: Int = 0) -> String? {
        guard depth < 8 else { return nil }
        var labels: [String] = []
        while offset < message.count {
            let length = message[offset]
            if length & 0xC0 == 0xC0 {
                guard offset + 1 < message.count else { return nil }
                var pointer = Int(length & 0x3F) << 8 | Int(message[offset + 1])
                offset += 2
                guard let rest = readName(message, &pointer, depth: depth + 1) else { return nil }
                if !rest.isEmpty { labels.append(rest) }
                return labels.joined(separator: ".")
            }
            offset += 1
            if length == 0 { return labels.joined(separator: ".") }
            guard offset + Int(length) <= message.count else { return nil }
            labels.append(String(decoding: message[offset..<offset + Int(length)], as: UTF8.self))
            offset += Int(length)
        }
        return nil
    }
}
