import Foundation
import Darwin

struct Device: Identifiable, Hashable {
    let mac: String
    let host: String
    let name: String
    var id: String { mac }
}
struct ConnectionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
final class GreeClient {
    let genericKey = "a3K8Bx%2r8Y7#xDh"
    let columns = ["Pow", "Mod", "SetTem", "WdSpd", "SwhSlp", "SwUpDn", "SvSt", "TemSen", "TemUn"]
    private var keys: [String: String] = [:]
    func clearSession() { keys.removeAll() }
    func crypt(_ data: Data, key: String, decrypt: Bool) throws -> Data {
        guard key.utf8.count == 16 else { throw ConnectionError(message: "Invalid device key.") }
        var output = Data(count: data.count + 16)
        let capacity = output.count
        var length = 0
        let result = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                Data(key.utf8).withUnsafeBytes { secret in
                    CCCrypt(CCOperation(decrypt ? kCCDecrypt : kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding), secret.baseAddress, 16, nil, source.baseAddress, data.count, destination.baseAddress, capacity, &length)
                }
            }
        }
        guard result == kCCSuccess else { throw ConnectionError(message: "Unsupported or invalid encrypted response. This version supports AES v1.") }
        return output.prefix(length)
    }
    func packet(_ payload: [String: Any], device: Device, key: String, binding: Bool = false) throws -> [String: Any] {
        ["cid": "app", "tcid": device.mac, "uid": 0, "t": "pack", "i": binding ? 1 : 0,
         "pack": try crypt(JSONSerialization.data(withJSONObject: payload), key: key, decrypt: false).base64EncodedString()]
    }
    func decode(_ data: Data, key: String) throws -> [String: Any] {
        guard let outer = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let encoded = outer["pack"] as? String, let encrypted = Data(base64Encoded: encoded),
              let inner = try JSONSerialization.jsonObject(with: crypt(encrypted, key: key, decrypt: true)) as? [String: Any]
        else { throw ConnectionError(message: "Invalid protocol response.") }
        return inner
    }
    private func exchange(_ payload: [String: Any], host: String, key: String, expectedType: String, mac: String? = nil, scan: Bool = false) throws -> [(String, [String: Any])] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw ConnectionError(message: "Cannot open network socket.") }
        defer { close(fd) }
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = UInt16(7000).bigEndian
        guard inet_pton(AF_INET, host, &destination.sin_addr) == 1 else { throw ConnectionError(message: "Enter a valid IPv4 address or broadcast address.") }
        let data = try JSONSerialization.data(withJSONObject: payload)
        let sent = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        guard sent == data.count else { throw ConnectionError(message: "Network send failed. Check Local Network permission.") }
        let deadline = Date().addingTimeInterval(scan ? 2 : 3)
        var replies: [(String, [String: Any])] = []
        while Date() < deadline {
            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pollDescriptor, 1, 100) > 0 else { continue }
            var bytes = [UInt8](repeating: 0, count: 8192)
            var source = sockaddr_in()
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &source) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &bytes, bytes.count, 0, $0, &size) }
            }
            guard count > 0, source.sin_port == UInt16(7000).bigEndian else { continue }
            var address = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &source.sin_addr, &address, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: address)
            guard scan || ip == host,
                  let decoded = try? decode(Data(bytes.prefix(count)), key: key), decoded["t"] as? String == expectedType else { continue }
            if let mac, let responseMAC = decoded["mac"] as? String, responseMAC != mac { continue }
            replies.append((ip, decoded))
            if !scan { return replies }
        }
        if !scan { throw ConnectionError(message: "No compatible response from the AC. Check its Wi-Fi connection, IP address, and AES v1 support.") }
        return replies
    }
    func discover(host: String) throws -> [Device] {
        let replies = try exchange(["t": "scan"], host: host, key: genericKey, expectedType: "dev", scan: true)
        var devices: [Device] = []
        for (ip, payload) in replies {
            guard let mac = payload["mac"] as? String ?? payload["cid"] as? String, !mac.isEmpty else { continue }
            if !devices.contains(where: { $0.mac == mac }) {
                devices.append(Device(mac: mac, host: ip, name: payload["name"] as? String ?? "Gree AC"))
            }
        }
        return devices
    }
    private func bind(_ device: Device) throws -> String {
        if let key = keys[device.mac] { return key }
        let request = try packet(["t": "bind", "mac": device.mac, "uid": 0], device: device, key: genericKey, binding: true)
        let reply = try exchange(request, host: device.host, key: genericKey, expectedType: "bindok", mac: device.mac)[0].1
        guard let key = reply["key"] as? String, key.utf8.count == 16, (reply["r"] as? Int ?? 200) == 200 else { throw ConnectionError(message: "AC binding failed.") }
        keys[device.mac] = key
        return key
    }
    func status(_ device: Device) throws -> [String: Int] {
        let key = try bind(device)
        let request = try packet(["t": "status", "mac": device.mac, "cols": columns], device: device, key: key)
        let reply = try exchange(request, host: device.host, key: key, expectedType: "dat", mac: device.mac)[0].1
        guard let names = reply["cols"] as? [String], let values = reply["dat"] as? [Int], names.count == values.count,
              Set(names).count == names.count, (reply["r"] as? Int ?? 200) == 200 else { throw ConnectionError(message: "Invalid status response.") }
        let state = Dictionary(uniqueKeysWithValues: zip(names, values))
        guard state["Pow"] != nil, state["SetTem"] != nil else { throw ConnectionError(message: "AC did not report power and temperature.") }
        return state
    }
    func command(_ device: Device, values: [String: Int]) throws {
        let key = try bind(device)
        let names = values.keys.sorted()
        let request = try packet(["t": "cmd", "opt": names, "p": names.map { values[$0]! }], device: device, key: key)
        let reply = try exchange(request, host: device.host, key: key, expectedType: "res", mac: device.mac)[0].1
        guard (reply["r"] as? Int ?? 200) == 200 else { throw ConnectionError(message: "AC rejected the command.") }
    }
}
