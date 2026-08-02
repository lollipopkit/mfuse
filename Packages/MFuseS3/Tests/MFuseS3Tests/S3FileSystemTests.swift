import Testing
import MFuseCore

@testable import MFuseS3

@Test func placeholder() async throws {
    // Integration tests require real S3 credentials
}

/// Credential problems must not be reported as an unreachable server, or the UI asks the
/// user to check the network instead of the keys.
@Test func credentialErrorsMapToAuthenticationFailed() {
    for code in [
        "AccessDenied",
        "InvalidAccessKeyId",
        "SignatureDoesNotMatch",
        "InvalidSecurity",
        "NotAuthorized"
    ] {
        let mapped = S3FileSystem.mapConnectionError(StubError(text: code), bucket: "b")
        guard case .authenticationFailed = mapped else {
            Issue.record("\(code) mapped to \(mapped) instead of .authenticationFailed")
            continue
        }
    }
}

@Test func missingBucketIsNamedInTheError() {
    let mapped = S3FileSystem.mapConnectionError(StubError(text: "NoSuchBucket"), bucket: "photos")
    guard case .connectionFailed(let message) = mapped else {
        Issue.record("expected .connectionFailed, got \(mapped)")
        return
    }
    #expect(message.contains("photos"))
}

/// SDK descriptions can carry response diagnostics from a custom endpoint, and error
/// descriptions are logged with public privacy — they must not reach the message.
@Test func unclassifiedErrorsDoNotLeakTheSDKDescription() {
    let secret = "x-amz-signature=deadbeef"
    let mapped = S3FileSystem.mapConnectionError(StubError(text: secret), bucket: "b")
    guard case .connectionFailed(let message) = mapped else {
        Issue.record("expected .connectionFailed, got \(mapped)")
        return
    }
    #expect(!message.contains(secret))
}

/// A RemoteFileSystemError raised inside connect() is already classified.
@Test func alreadyClassifiedErrorsPassThrough() {
    let mapped = S3FileSystem.mapConnectionError(
        RemoteFileSystemError.authenticationFailed,
        bucket: "b"
    )
    guard case .authenticationFailed = mapped else {
        Issue.record("expected .authenticationFailed, got \(mapped)")
        return
    }
}

private struct StubError: Error, CustomStringConvertible {
    let text: String
    var description: String { text }
}
