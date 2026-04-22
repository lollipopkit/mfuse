import XCTest
@testable import MFuseWebDAV

final class WebDAVXMLParserTests: XCTestCase {

    private func parse(_ xml: String) -> [WebDAVResource] {
        let parser = WebDAVXMLParser()
        return parser.parse(data: Data(xml.utf8))
    }

    // MARK: - Basic Parsing

    func testParseFileEntry() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/files/readme.txt</D:href>
            <D:propstat>
              <D:prop>
                <D:displayname>readme.txt</D:displayname>
                <D:getcontentlength>1024</D:getcontentlength>
                <D:getlastmodified>Mon, 01 Jan 2024 12:00:00 GMT</D:getlastmodified>
                <D:resourcetype/>
              </D:prop>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """
        let resources = parse(xml)
        XCTAssertEqual(resources.count, 1)
        let res = resources[0]
        XCTAssertEqual(res.href, "/files/readme.txt")
        XCTAssertFalse(res.isCollection)
        XCTAssertEqual(res.contentLength, 1024)
        XCTAssertNotNil(res.lastModified)
        XCTAssertEqual(res.displayName, "readme.txt")
    }

    func testParseCollectionEntry() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/files/subdir/</D:href>
            <D:propstat>
              <D:prop>
                <D:displayname>subdir</D:displayname>
                <D:resourcetype><D:collection/></D:resourcetype>
              </D:prop>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """
        let resources = parse(xml)
        XCTAssertEqual(resources.count, 1)
        XCTAssertTrue(resources[0].isCollection)
        XCTAssertEqual(resources[0].displayName, "subdir")
    }

    // MARK: - Multiple Responses

    func testParseMultipleResponses() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/files/</D:href>
            <D:propstat>
              <D:prop>
                <D:resourcetype><D:collection/></D:resourcetype>
              </D:prop>
            </D:propstat>
          </D:response>
          <D:response>
            <D:href>/files/a.txt</D:href>
            <D:propstat>
              <D:prop>
                <D:getcontentlength>100</D:getcontentlength>
                <D:resourcetype/>
              </D:prop>
            </D:propstat>
          </D:response>
          <D:response>
            <D:href>/files/b.txt</D:href>
            <D:propstat>
              <D:prop>
                <D:getcontentlength>200</D:getcontentlength>
                <D:resourcetype/>
              </D:prop>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """
        let resources = parse(xml)
        XCTAssertEqual(resources.count, 3)
        XCTAssertTrue(resources[0].isCollection)
        XCTAssertEqual(resources[1].contentLength, 100)
        XCTAssertEqual(resources[2].contentLength, 200)
    }

    // MARK: - Date Formats

    func testParseRFC2822Date() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/file.txt</D:href>
            <D:propstat>
              <D:prop>
                <D:getlastmodified>Wed, 15 Mar 2023 08:30:00 GMT</D:getlastmodified>
                <D:resourcetype/>
              </D:prop>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """
        let resources = parse(xml)
        XCTAssertEqual(resources.count, 1)
        XCTAssertNotNil(resources[0].lastModified)
    }

    // MARK: - Edge Cases

    func testEmptyMultistatus() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <D:multistatus xmlns:D="DAV:">
        </D:multistatus>
        """
        let resources = parse(xml)
        XCTAssertTrue(resources.isEmpty)
    }

    func testNoNamespacePrefix() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <multistatus xmlns="DAV:">
          <response>
            <href>/test.txt</href>
            <propstat>
              <prop>
                <getcontentlength>42</getcontentlength>
                <resourcetype/>
              </prop>
            </propstat>
          </response>
        </multistatus>
        """
        let resources = parse(xml)
        XCTAssertEqual(resources.count, 1)
        XCTAssertEqual(resources[0].href, "/test.txt")
        XCTAssertEqual(resources[0].contentLength, 42)
    }

    func testMissingOptionalFields() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/minimal.txt</D:href>
            <D:propstat>
              <D:prop>
                <D:resourcetype/>
              </D:prop>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """
        let resources = parse(xml)
        XCTAssertEqual(resources.count, 1)
        XCTAssertEqual(resources[0].contentLength, 0)
        XCTAssertNil(resources[0].lastModified)
        XCTAssertNil(resources[0].displayName)
    }

    func testInvalidXML() {
        let xml = "this is not xml at all"
        let resources = parse(xml)
        XCTAssertTrue(resources.isEmpty)
    }
}
