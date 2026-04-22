import XCTest
@testable import MFuseFTP

final class FTPDirectoryParserTests: XCTestCase {

    // MARK: - Basic Parsing

    func testParseRegularFile() {
        let listing = "-rw-r--r--  1 user group  12345 Jan 15 10:30 readme.txt"
        let entries = FTPDirectoryParser.parse(listing)
        XCTAssertEqual(entries.count, 1)
        let entry = entries[0]
        XCTAssertEqual(entry.name, "readme.txt")
        XCTAssertFalse(entry.isDirectory)
        XCTAssertEqual(entry.size, 12345)
        XCTAssertNotNil(entry.modificationDate)
    }

    func testParseDirectory() {
        let listing = "drwxr-xr-x  2 user group  4096 Mar 20 14:00 documents"
        let entries = FTPDirectoryParser.parse(listing)
        XCTAssertEqual(entries.count, 1)
        let entry = entries[0]
        XCTAssertEqual(entry.name, "documents")
        XCTAssertTrue(entry.isDirectory)
        XCTAssertEqual(entry.size, 4096)
    }

    func testParseSymlink() {
        let listing = "lrwxrwxrwx  1 user group  11 Feb 10 09:00 link -> target.txt"
        let entries = FTPDirectoryParser.parse(listing)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "link")
    }

    func testSkipDotEntries() {
        let listing = """
        drwxr-xr-x  2 user group  4096 Jan 01 00:00 .
        drwxr-xr-x  3 user group  4096 Jan 01 00:00 ..
        -rw-r--r--  1 user group  100 Jan 01 00:00 file.txt
        """
        let entries = FTPDirectoryParser.parse(listing)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "file.txt")
    }

    func testSkipTotalLine() {
        let listing = """
        total 24
        -rw-r--r--  1 user group  8192 Jan 01 00:00 data.bin
        """
        let entries = FTPDirectoryParser.parse(listing)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "data.bin")
    }

    // MARK: - Permissions

    func testParsePermissions() {
        let listing = "-rwxr-x---  1 user group  0 Jan 01 00:00 script.sh"
        let entries = FTPDirectoryParser.parse(listing)
        XCTAssertEqual(entries.count, 1)
        // rwxr-x--- = 0o750
        XCTAssertEqual(entries[0].permissions, 0o750)
    }

    func testParseSetuidPermissions() {
        let listing = "-rwsr-xr-x  1 root root  0 Jan 01 00:00 suid_prog"
        let entries = FTPDirectoryParser.parse(listing)
        XCTAssertEqual(entries.count, 1)
        // rws r-x r-x = setuid(4000) + 755 = 0o4755
        XCTAssertEqual(entries[0].permissions, 0o4755)
    }

    func testParseStickyBit() {
        let listing = "drwxrwxrwt  2 root root  4096 Jan 01 00:00 tmp"
        let entries = FTPDirectoryParser.parse(listing)
        XCTAssertEqual(entries.count, 1)
        // rwx rwx rwt = sticky(1000) + 777 = 0o1777
        XCTAssertEqual(entries[0].permissions, 0o1777)
    }

    // MARK: - Date Parsing

    func testParseDateWithTime() {
        let listing = "-rw-r--r--  1 user group  0 Dec 25 23:59 holiday.txt"
        let entries = FTPDirectoryParser.parse(listing)
        XCTAssertEqual(entries.count, 1)
        XCTAssertNotNil(entries[0].modificationDate)
    }

    func testParseDateWithTimeUsesUTCForParsingAndInference() {
        let originalTimeZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(secondsFromGMT: 5 * 60 * 60)!
        defer { NSTimeZone.default = originalTimeZone }

        let listing = "-rw-r--r--  1 user group  0 Jan 01 00:30 boundary.txt"
        let entries = FTPDirectoryParser.parse(listing)

        XCTAssertEqual(entries.count, 1)
        guard let modificationDate = entries[0].modificationDate else {
            return XCTFail("Expected modification date")
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.month, .day, .hour, .minute], from: modificationDate)

        XCTAssertEqual(components.month, 1)
        XCTAssertEqual(components.day, 1)
        XCTAssertEqual(components.hour, 0)
        XCTAssertEqual(components.minute, 30)
    }

    func testParseDateWithYear() {
        let listing = "-rw-r--r--  1 user group  0 Jan 01  2023 old_file.txt"
        let entries = FTPDirectoryParser.parse(listing)
        XCTAssertEqual(entries.count, 1)
        XCTAssertNotNil(entries[0].modificationDate)
    }

    // MARK: - Edge Cases

    func testEmptyListing() {
        let entries = FTPDirectoryParser.parse("")
        XCTAssertTrue(entries.isEmpty)
    }

    func testFilenameWithSpaces() {
        let listing = "-rw-r--r--  1 user group  100 Jan 01 00:00 my file name.txt"
        let entries = FTPDirectoryParser.parse(listing)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "my file name.txt")
    }

    func testMultipleEntries() {
        let listing = """
        total 100
        drwxr-xr-x  3 user group  4096 Jan 01 00:00 dir1
        drwxr-xr-x  2 user group  4096 Jan 02 00:00 dir2
        -rw-r--r--  1 user group  1024 Jan 03 00:00 file1.txt
        -rw-r--r--  1 user group  2048 Jan 04 00:00 file2.txt
        lrwxrwxrwx  1 user group  5 Jan 05 00:00 link1 -> file1.txt
        """
        let entries = FTPDirectoryParser.parse(listing)
        XCTAssertEqual(entries.count, 5)
        XCTAssertTrue(entries[0].isDirectory)
        XCTAssertTrue(entries[1].isDirectory)
        XCTAssertFalse(entries[2].isDirectory)
        XCTAssertFalse(entries[3].isDirectory)
        XCTAssertEqual(entries[4].name, "link1")
    }

    func testMalformedLine() {
        let listing = "this is not a valid ls -l line"
        let entries = FTPDirectoryParser.parse(listing)
        XCTAssertTrue(entries.isEmpty)
    }

    func testZeroSizeFile() {
        let listing = "-rw-r--r--  1 user group  0 Jan 01 00:00 empty.txt"
        let entries = FTPDirectoryParser.parse(listing)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].size, 0)
    }
}
