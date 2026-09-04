import XCTest
@testable import InfinitusCore

final class TeamIdentityTests: XCTestCase {
    func testBase32MatchesRFC4648Vectors() {
        XCTAssertEqual(Base32.encode(Data()), "")
        XCTAssertEqual(Base32.encode(Data("f".utf8)), "my")
        XCTAssertEqual(Base32.encode(Data("fo".utf8)), "mzxq")
        XCTAssertEqual(Base32.encode(Data("foo".utf8)), "mzxw6")
        XCTAssertEqual(Base32.encode(Data("foobar".utf8)), "mzxw6ytboi")
    }

    func testCanonicalJSONIsSortedAndStable() throws {
        struct Doc: Codable { var b: Int; var a: String; var path: String }
        let data = try CanonicalJSON.encode(Doc(b: 2, a: "x", path: "m/k/1"))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"a":"x","b":2,"path":"m/k/1"}"#)
        XCTAssertEqual(try CanonicalJSON.decode(Doc.self, from: data).path, "m/k/1")
    }

    func testIdentityIsDeterministicFromTheSecret() throws {
        let secret = Data((0..<32).map { UInt8($0) })
        let a = try TeamIdentity(secret: secret)
        let b = try TeamIdentity(secret: secret)
        XCTAssertEqual(a.keys, b.keys)
        XCTAssertEqual(a.kid.count, 26)
        XCTAssertTrue(a.kid.allSatisfy { "abcdefghijklmnopqrstuvwxyz234567".contains($0) })
        XCTAssertEqual(a.kid, TeamKeys.kid(forEncryptionKey: a.encryption.publicKey.rawRepresentation))
        XCTAssertNotEqual(a.keys, TeamIdentity.random().keys)
        XCTAssertThrowsError(try TeamIdentity(secret: Data([1, 2, 3])))
    }

    func testSignaturesVerifyWithThePublishedKey() throws {
        let id = TeamIdentity.random()
        let msg = Data("hello".utf8)
        let sig = try id.sign(msg)
        XCTAssertTrue(try id.keys.signingKey().isValidSignature(sig, for: msg))
        XCTAssertFalse(try id.keys.signingKey().isValidSignature(sig, for: Data("hellp".utf8)))
        XCTAssertEqual(try id.keys.encryptionKey().rawRepresentation, id.encryption.publicKey.rawRepresentation)
    }
}
