import MFuseCore
import NFS
import Testing

@testable import MFuseNFS

// The protocol is tested in nfs.swift, and operations against a server in MFuseE2E.

@Test func clientErrorsMapToRemoteErrors() {
    let path = RemotePath("/a/b")
    let expected: [(NFSClientError, RemoteFileSystemError)] = [
        (.notFound(path: "/a/b"), .notFound(path)),
        (.alreadyExists(path: "/a/b"), .alreadyExists(path)),
        (.notDirectory(path: "/a/b"), .notDirectory(path)),
        (.isDirectory(path: "/a/b"), .notFile(path)),
        (.permissionDenied(path: "/a/b"), .permissionDenied(path)),
        (.notConnected, .notConnected)
    ]
    for (error, remoteError) in expected {
        #expect(String(describing: NFSFileSystem.mapped(error, path: path)) == String(describing: remoteError))
    }
}

@Test func refusedMountKeepsTheInsecureHint() {
    guard case .connectionFailed(let message) = NFSFileSystem.connectionError(
        NFSClientError.mountRefused(MountStatusError(status: 13))
    ) else {
        Issue.record("expected connectionFailed")
        return
    }
    #expect(message.contains("insecure"))
}
