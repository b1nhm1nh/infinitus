import XCTest
@testable import InfinitusCore

final class AwsLoginTests: XCTestCase {
    func testDetectsTheProfileFromTheBrokerAndCliSignatures() {
        XCTAssertEqual(AwsLogin.profile(in: """
            [aws-cred-broker] could not refresh credentials for 'papaya-login'.
              aws said: aws: [ERROR]: Your session has expired. Please reauthenticate using 'aws login'.
              Fix: aws login --profile papaya-login
            """), "papaya-login")
        XCTAssertEqual(AwsLogin.profile(in: "aws: [ERROR]: Your session has expired. Please reauthenticate using 'aws login'."), "default")
        XCTAssertEqual(AwsLogin.profile(in: "Error when retrieving token from sso: Token has expired and refresh failed\nRun: aws sso login --profile papaya-dev"), "papaya-dev")
        XCTAssertNil(AwsLogin.profile(in: "aws login --profile x is documented here"), "no failure, no need")
        XCTAssertNil(AwsLogin.profile(in: "all good"))
    }

    func testFlowFollowsTheProfileKindInTheConfig() {
        let config = """
        [default]
        credential_process = broker
        [profile papaya-login]
        login_session = papaya
        region = ap-southeast-1
        [sso-session papaya]
        sso_start_url = https://x.awsapps.com/start
        [profile papaya-dev]
        sso_session = papaya
        sso_account_id = 1
        """
        XCTAssertEqual(AwsLogin.flow(profile: "papaya-dev", configText: config), .deviceCode)
        XCTAssertEqual(AwsLogin.flow(profile: "papaya-login", configText: config), .relay)
        XCTAssertEqual(AwsLogin.flow(profile: "default", configText: config), .relay)
        XCTAssertEqual(AwsLogin.flow(profile: "missing", configText: config), .relay)
    }

    func testParsesBothCliPrompts() {
        let remote = AwsLogin.parseOutput("""
        Browser will not be automatically opened.
        Please visit the following URL:

        https://signin.aws.amazon.com/oauth?x=1

        Enter the authorization code displayed in your browser: 
        """)
        XCTAssertEqual(remote.url, "https://signin.aws.amazon.com/oauth?x=1")
        XCTAssertTrue(remote.wantsCode)
        XCTAssertNil(remote.userCode)
        XCTAssertFalse(remote.succeeded)

        let device = AwsLogin.parseOutput("Browser will not be automatically opened.\r\nPlease visit the following URL:\r\n\r\nhttps://device.sso.us-east-1.amazonaws.com/\r\n\r\nThen enter the code:\r\n\r\nABCD-EFGH\r\n")
        XCTAssertEqual(device.url, "https://device.sso.us-east-1.amazonaws.com/")
        XCTAssertEqual(device.userCode, "ABCD-EFGH")
        XCTAssertFalse(device.wantsCode)

        XCTAssertTrue(AwsLogin.parseOutput("Updated profile papaya-login to use arn:aws:sts::1:assumed-role/x credentials.").succeeded)
        XCTAssertTrue(AwsLogin.parseOutput("Successfully logged into Start URL: https://x").succeeded)
    }

    func testRelayCallbackPortAndValidation() {
        let authorize = "https://ap-southeast-1.signin.aws.amazon.com/v1/authorize?response_type=code&client_id=x&redirect_uri=http%3A%2F%2F127.0.0.1%3A60861%2Foauth%2Fcallback&code_challenge=y"
        XCTAssertEqual(AwsLogin.callbackPort(inURL: authorize), 60861)
        XCTAssertNil(AwsLogin.callbackPort(inURL: "https://x/authorize?redirect_uri=https%3A%2F%2Fsignin.aws%2Fconfirm"), "the --remote flow has no localhost callback")
        XCTAssertTrue(AwsLogin.isValidCallback("http://127.0.0.1:60861/oauth/callback?code=abc&state=s", port: 60861))
        XCTAssertFalse(AwsLogin.isValidCallback("http://127.0.0.1:60862/oauth/callback?code=abc", port: 60861), "wrong port")
        XCTAssertFalse(AwsLogin.isValidCallback("http://evil.example/oauth/callback?code=abc", port: 60861))
        XCTAssertFalse(AwsLogin.isValidCallback("http://127.0.0.1:60861/other?code=abc", port: 60861))
        XCTAssertFalse(AwsLogin.isValidCallback("http://127.0.0.1:60861/oauth/callback?error=denied", port: 60861))
        XCTAssertEqual(AwsLogin.arguments(profile: "p", flow: .relay), ["login", "--profile", "p"])
    }

    func testCodesAreShortAndPlain() {
        XCTAssertTrue(AwsLogin.isValidCode("ABCD-EFGH"))
        XCTAssertTrue(AwsLogin.isValidCode("a1b2c3"))
        XCTAssertFalse(AwsLogin.isValidCode(""))
        XCTAssertFalse(AwsLogin.isValidCode("abc\n"))
        XCTAssertFalse(AwsLogin.isValidCode("x; rm -rf"))
    }

    func testArgumentsPerFlow() {
        XCTAssertEqual(AwsLogin.arguments(profile: "p", flow: .remote), ["login", "--remote", "--profile", "p"])
        XCTAssertEqual(AwsLogin.arguments(profile: "p", flow: .deviceCode),
                       ["sso", "login", "--use-device-code", "--no-browser", "--profile", "p"])
        XCTAssertEqual(AwsLogin.arguments(profile: "p", flow: .local), ["login", "--profile", "p"])
    }

    func testWireShapesRoundTrip() throws {
        let item = AwsLogin.Item(profile: "papaya-login", flow: .remote, pid: 42, sessionLabel: "banyan",
                                 state: AwsLogin.State(profile: "papaya-login", flow: .remote, phase: .waitingForCode,
                                                       url: "https://x", startedAt: 1, pid: 42))
        let data = try JSONEncoder().encode(item)
        XCTAssertEqual(try JSONDecoder().decode(AwsLogin.Item.self, from: data), item)
        let start = try JSONDecoder().decode(AwsLogin.StartRequest.self, from: Data(#"{"profile":"p"}"#.utf8))
        XCTAssertEqual(start, AwsLogin.StartRequest(profile: "p"))
    }
}

final class AwsLoginProgressTests: XCTestCase {
    func testSessionProgressReadsTheLapsedProfileOffTheNewestToolResults() {
        let failed = #"{"type":"user","timestamp":"2026-09-03T08:00:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"[aws-cred-broker] could not refresh credentials for 'papaya-login'.\n  aws said: aws: [ERROR]: Your session has expired. Please reauthenticate using 'aws login'.\n  Fix: aws login --profile papaya-login"}]}}"#
        let fine = #"{"type":"user","timestamp":"2026-09-03T08:01:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":[{"type":"text","text":"ok"}]}]}}"#
        XCTAssertEqual(SessionProgress.parse(lines: [failed, fine]).awsLoginProfile, "papaya-login")
        XCTAssertNil(SessionProgress.parse(lines: [fine]).awsLoginProfile)
        // The CLI's own error names no profile — the failed command does.
        let use = #"{"type":"assistant","timestamp":"2026-09-03T08:00:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t9","name":"Bash","input":{"command":"AWS_PROFILE=papaya-dev aws sts get-caller-identity"}}]}}"#
        let raw = #"{"type":"user","timestamp":"2026-09-03T08:00:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t9","content":"aws: [ERROR]: Your session has expired. Please reauthenticate using 'aws login'."}]}}"#
        XCTAssertEqual(SessionProgress.parse(lines: [use, raw]).awsLoginProfile, "papaya-dev")
        XCTAssertEqual(AwsLogin.profile(inCommand: "aws s3 ls --profile=banyan"), "banyan")
        XCTAssertNil(AwsLogin.profile(inCommand: "aws s3 ls"))
        // Scrolls out of the scan window once the session moves on.
        let later = Array(repeating: fine, count: SessionProgress.awsLoginScanEntries)
        XCTAssertNil(SessionProgress.parse(lines: [failed] + later).awsLoginProfile)
    }
}
