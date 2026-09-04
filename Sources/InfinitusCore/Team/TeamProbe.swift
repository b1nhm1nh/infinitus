import Foundation
import Crypto
import CZlib

// Temporary: proves swift-crypto and zlib link on this platform. Task 2
// replaces it with the real identity code.
enum TeamProbe {
    static func probe() -> Int {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return key.publicKey.rawRepresentation.count + Int(compressBound(1))
    }
}
