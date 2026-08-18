import XCTest
@testable import TermPilotApp
@testable import TermPilotRemote

final class SSHCredentialKeyTests: XCTestCase {
    func testKeyGeneratorScriptIsPackagedAsAnApplicationResource() {
        let resource = AppResourceLocator.url(
            forResource: "termpilot-keygen",
            withExtension: "cjs",
            subdirectory: "keygen"
        ) ?? AppResourceLocator.url(
            forResource: "termpilot-keygen",
            withExtension: "cjs"
        )
        XCTAssertNotNil(resource)
    }

    func testKeyGenerationDefaultsMatchCredentialUI() throws {
        let ed25519 = try SSHKeyGenerationRequest(
            keyType: .ed25519,
            bits: 4_096
        ).validated()
        XCTAssertNil(ed25519.bits)

        let ecdsa = try SSHKeyGenerationRequest(
            keyType: .ecdsa
        ).validated()
        XCTAssertEqual(ecdsa.bits, 256)

        let rsa = try SSHKeyGenerationRequest(
            keyType: .rsa
        ).validated()
        XCTAssertEqual(rsa.bits, 4_096)
    }

    func testKeyGenerationRejectsUnlistedStrengths() {
        XCTAssertThrowsError(
            try SSHKeyGenerationRequest(
                keyType: .ecdsa,
                bits: 255
            ).validated()
        )
        XCTAssertThrowsError(
            try SSHKeyGenerationRequest(
                keyType: .rsa,
                bits: 3_072
            ).validated()
        )
    }

    func testAuthorizedKeyCommandIsIdempotentAndShellQuotesComment() throws {
        let command = try SSHAuthorizedKeyCommand.make(
            publicKey:
                "ssh-ed25519 dGVzdA== pilot's key"
        )
        XCTAssertTrue(command.contains("grep -Fqx"))
        XCTAssertTrue(command.contains("|| printf"))
        XCTAssertTrue(command.contains("pilot'\\''s key"))
        XCTAssertTrue(command.contains("chmod 600"))
    }

    func testAuthorizedKeyCommandRejectsMultipleLines() {
        XCTAssertThrowsError(
            try SSHAuthorizedKeyCommand.make(
                publicKey: "ssh-ed25519 AAAA\nssh-rsa BBBB"
            )
        )
    }
}
