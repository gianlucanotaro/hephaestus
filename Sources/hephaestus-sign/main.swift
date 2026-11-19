import CryptoKit
import Foundation

// Release signing tool (CryptoKit + Foundation only). Keys are raw 32-byte Ed25519 values, base64-encoded.
//   hephaestus-sign keygen <private-key-file>            writes the private key (0600), prints the PUBLIC key
//   hephaestus-sign sign <private-key-file> <file>       writes <file>.sig (base64 signature)
//   hephaestus-sign verify <public-key-base64> <file> <sig-file>   exit 0 if valid

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func readText(_ path: String) -> String {
    guard let d = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "keygen" where args.count == 2:
    let path = args[1]
    guard !FileManager.default.fileExists(atPath: path) else { fail("refusing to overwrite existing \(path)") }
    let key = Curve25519.Signing.PrivateKey()
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard fd >= 0 else { fail("cannot create \(path) (does its directory exist?)") }
    let line = Data((key.rawRepresentation.base64EncodedString() + "\n").utf8)
    let written = line.withUnsafeBytes { write(fd, $0.baseAddress, line.count) }
    close(fd)
    guard written == line.count else { fail("write failed") }
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "sign" where args.count == 3:
    guard let raw = Data(base64Encoded: readText(args[1])), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("invalid private key file")
    }
    guard let data = FileManager.default.contents(atPath: args[2]) else { fail("cannot read \(args[2])") }
    let sig = try key.signature(for: data)
    do { try (sig.base64EncodedString() + "\n").write(toFile: args[2] + ".sig", atomically: true, encoding: .utf8) } catch { fail("cannot write signature") }

case "verify" where args.count == 4:
    guard let raw = Data(base64Encoded: args[1]), raw.count == 32, let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
        fail("invalid public key (empty or not a 32-byte base64 key)")
    }
    guard let data = FileManager.default.contents(atPath: args[2]), let sig = Data(base64Encoded: readText(args[3])) else {
        fail("cannot read file or signature")
    }
    guard key.isValidSignature(sig, for: data) else { fail("signature INVALID", code: 3) }
    print("signature valid")

default:
    fail("usage:\n  hephaestus-sign keygen <private-key-file>\n  hephaestus-sign sign <private-key-file> <file>\n  hephaestus-sign verify <public-key-base64> <file> <sig-file>", code: 2)
}
