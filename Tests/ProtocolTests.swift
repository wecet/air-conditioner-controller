import Foundation
@main
struct ProtocolTests {
    static func main() throws {
        let client = GreeClient()
        let key = "0123456789abcdef"
        let plaintext = Data("0123456789abcdef".utf8)
        let encrypted = try client.crypt(plaintext, key: key, decrypt: false)
        // Independently verified with openssl AES-128-ECB, without padding.
        precondition(encrypted.prefix(16).map { String(format: "%02x", $0) }.joined() == "72727e881edcfd0100a718687909b565")
        let decrypted = try client.crypt(encrypted, key: key, decrypt: true)
        precondition(decrypted == plaintext)
        let device = Device(mac: "aabbccddeeff", host: "127.0.0.1", name: "Test")
        let packet = try client.packet(["t": "bind", "mac": device.mac, "uid": 0], device: device, key: client.genericKey, binding: true)
        precondition(packet["tcid"] as? String == device.mac)
        precondition(packet["i"] as? Int == 1)
        let decoded = try client.decode(JSONSerialization.data(withJSONObject: packet), key: client.genericKey)
        precondition(decoded["t"] as? String == "bind")
        do { _ = try client.crypt(plaintext, key: "short", decrypt: false); fatalError("Invalid key accepted") } catch {}
        do { _ = try client.discover(host: "invalid"); fatalError("Invalid address accepted") } catch {}
        do { _ = try client.decode(Data("{}".utf8), key: key); fatalError("Invalid envelope accepted") } catch {}
        print("Protocol checks passed")
    }
}
