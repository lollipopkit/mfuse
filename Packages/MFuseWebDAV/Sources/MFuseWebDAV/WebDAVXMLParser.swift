import Foundation

/// Parsed entry from a WebDAV PROPFIND multistatus response.
struct WebDAVResource {
    let href: String
    let isCollection: Bool
    let contentLength: UInt64
    let lastModified: Date?
    let displayName: String?
}

/// Parses WebDAV `multistatus` XML from PROPFIND responses.
final class WebDAVXMLParser: NSObject, XMLParserDelegate {

    private var resources: [WebDAVResource] = []

    // Parsing state
    private var currentHref: String?
    private var currentIsCollection = false
    private var currentContentLength: UInt64 = 0
    private var currentLastModified: Date?
    private var currentDisplayName: String?
    private var currentText = ""
    private var insideResponse = false
    private var insideResourceType = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    private static let iso8601Formatter = ISO8601DateFormatter()

    func parse(data: Data) -> [WebDAVResource] {
        resources = []
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return resources
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let local = localName(elementName)
        currentText = ""

        switch local {
        case "response":
            insideResponse = true
            currentHref = nil
            currentIsCollection = false
            currentContentLength = 0
            currentLastModified = nil
            currentDisplayName = nil
        case "resourcetype":
            insideResourceType = true
        case "collection":
            if insideResourceType {
                currentIsCollection = true
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let local = localName(elementName)
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch local {
        case "href":
            if insideResponse { currentHref = text }
        case "displayname":
            if insideResponse { currentDisplayName = text }
        case "getcontentlength":
            currentContentLength = UInt64(text) ?? 0
        case "getlastmodified":
            currentLastModified = Self.dateFormatter.date(from: text)
                ?? Self.iso8601Formatter.date(from: text)
        case "resourcetype":
            insideResourceType = false
        case "response":
            if let href = currentHref {
                resources.append(WebDAVResource(
                    href: href,
                    isCollection: currentIsCollection,
                    contentLength: currentContentLength,
                    lastModified: currentLastModified,
                    displayName: currentDisplayName
                ))
            }
            insideResponse = false
        default:
            break
        }
    }

    /// Strip namespace prefix: "D:href" → "href", "DAV::href" → "href"
    private func localName(_ name: String) -> String {
        if let idx = name.lastIndex(of: ":") {
            return String(name[name.index(after: idx)...])
        }
        return name
    }
}
