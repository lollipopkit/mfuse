import Testing

@testable import MFuseFTP

// Transfers against real servers are covered by MFuseE2E.

@Test func parsesEPSVReply() throws {
    #expect(try FTPConnection.parseEPSV("229 Entering Extended Passive Mode (|||6446|)") == 6446)
    #expect(try FTPConnection.parseEPSV("229 Entering Extended Passive Mode (!!!40001!)") == 40001)
}

@Test func rejectsMalformedEPSVReply() {
    for reply in [
        "229 Entering Extended Passive Mode",
        "229 Entering Extended Passive Mode (||6446|)",
        "229 Entering Extended Passive Mode (|||0|)",
        "229 Entering Extended Passive Mode (|||70000|)",
        "229 Entering Extended Passive Mode (|||port|)"
    ] {
        #expect(throws: FTPError.self) { try FTPConnection.parseEPSV(reply) }
    }
}

@Test func parsesPASVReply() throws {
    let (host, port) = try FTPConnection.parsePASV("227 Entering Passive Mode (192,168,1,20,156,64)")
    #expect(host == "192.168.1.20")
    #expect(port == 156 * 256 + 64)
}

@Test func rejectsMalformedPASVReply() {
    for reply in [
        "227 Entering Passive Mode",
        "227 Entering Passive Mode (192,168,1,20,156)",
        "227 Entering Passive Mode (192,168,1,300,156,64)"
    ] {
        #expect(throws: FTPError.self) { try FTPConnection.parsePASV(reply) }
    }
}
