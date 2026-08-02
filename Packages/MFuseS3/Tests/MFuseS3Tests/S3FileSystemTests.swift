import Testing

@testable import MFuseS3

@Test func placeholder() async throws {
    // Integration tests require real S3 credentials
}

/// Regression coverage for configs saved before the editor stopped exposing a Port field
/// for S3. Those carry the port outside the endpoint string.
@Test func configuredPortIsAppliedWhenEndpointOmitsIt() {
    #expect(
        S3FileSystem.endpoint("http://localhost", applyingConfiguredPort: 9000)
            == "http://localhost:9000"
    )
}

@Test func endpointOwnPortWins() {
    #expect(
        S3FileSystem.endpoint("http://localhost:9000", applyingConfiguredPort: 443)
            == "http://localhost:9000"
    )
}

@Test func schemeDefaultPortIsNotAppended() {
    #expect(
        S3FileSystem.endpoint("https://s3.amazonaws.com", applyingConfiguredPort: 443)
            == "https://s3.amazonaws.com"
    )
    #expect(
        S3FileSystem.endpoint("http://minio.internal", applyingConfiguredPort: 80)
            == "http://minio.internal"
    )
}

@Test func malformedEndpointIsLeftAlone() {
    #expect(
        S3FileSystem.endpoint("not a url", applyingConfiguredPort: 9000) == "not a url"
    )
}
