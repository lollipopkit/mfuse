import FileProvider
import MFuseCore
import UniformTypeIdentifiers

/// The File Provider item adapter — bridges `RemoteItem` to `NSFileProviderItem`.
public final class FileProviderItem: NSObject, NSFileProviderItem {

    private let remoteItem: RemoteItem?
    private let parentID: NSFileProviderItemIdentifier
    private let explicitIdentifier: NSFileProviderItemIdentifier?
    private let explicitFilename: String?
    private let explicitContentType: UTType?
    private let explicitCapabilities: NSFileProviderItemCapabilities?

    public init(remoteItem: RemoteItem, parentID: NSFileProviderItemIdentifier) {
        self.remoteItem = remoteItem
        self.parentID = parentID
        self.explicitIdentifier = nil
        self.explicitFilename = nil
        self.explicitContentType = nil
        self.explicitCapabilities = nil
        super.init()
    }

    private init(
        identifier: NSFileProviderItemIdentifier,
        filename: String,
        parentID: NSFileProviderItemIdentifier,
        contentType: UTType = .folder,
        capabilities: NSFileProviderItemCapabilities = [.allowsReading, .allowsWriting, .allowsAddingSubItems, .allowsContentEnumerating]
    ) {
        self.remoteItem = nil
        self.parentID = parentID
        self.explicitIdentifier = identifier
        self.explicitFilename = filename
        self.explicitContentType = contentType
        self.explicitCapabilities = capabilities
        super.init()
    }

    // MARK: - Required

    public var itemIdentifier: NSFileProviderItemIdentifier {
        if let explicitIdentifier {
            return explicitIdentifier
        }
        guard let remoteItem else {
            return .rootContainer
        }
        if remoteItem.path.isRoot {
            return .rootContainer
        }
        return NSFileProviderItemIdentifier(remoteItem.path.absoluteString)
    }

    public var parentItemIdentifier: NSFileProviderItemIdentifier {
        parentID
    }

    public var filename: String {
        if let explicitFilename {
            return explicitFilename
        }
        guard let remoteItem else {
            return "Item"
        }
        return remoteItem.name
    }

    public var contentType: UTType {
        if let explicitContentType {
            return explicitContentType
        }
        guard let remoteItem else {
            return .folder
        }
        if remoteItem.isDirectory {
            return .folder
        }
        if let ext = remoteItem.path.pathExtension,
           let type = UTType(filenameExtension: ext) {
            return type
        }
        return .data
    }

    public var capabilities: NSFileProviderItemCapabilities {
        if let explicitCapabilities {
            return explicitCapabilities
        }
        guard let remoteItem else {
            return [.allowsReading]
        }
        if remoteItem.isDirectory {
            return [.allowsReading, .allowsWriting, .allowsAddingSubItems,
                    .allowsContentEnumerating, .allowsDeleting, .allowsRenaming,
                    .allowsReparenting]
        }
        return [.allowsReading, .allowsWriting, .allowsDeleting, .allowsRenaming,
                .allowsReparenting]
    }

    // MARK: - Optional metadata

    public var documentSize: NSNumber? {
        guard let remoteItem else { return nil }
        return NSNumber(value: remoteItem.size)
    }

    public var contentModificationDate: Date? {
        guard let remoteItem else { return nil }
        return remoteItem.modificationDate
    }

    public var creationDate: Date? {
        guard let remoteItem else { return nil }
        return remoteItem.creationDate
    }

    public var itemVersion: NSFileProviderItemVersion {
        guard let remoteItem else {
            let version = Data("synthetic".utf8)
            return NSFileProviderItemVersion(contentVersion: version, metadataVersion: version)
        }
        let contentVersion = "\(remoteItem.modificationDate.timeIntervalSince1970)_\(remoteItem.size)"
            .data(using: .utf8) ?? Data()
        let metadataVersion = contentVersion
        return NSFileProviderItemVersion(contentVersion: contentVersion, metadataVersion: metadataVersion)
    }

}

// MARK: - Convenience initializers

extension FileProviderItem {
    /// Create a root container item for a domain.
    public static func rootItem(name: String) -> FileProviderItem {
        FileProviderItem(
            identifier: .rootContainer,
            filename: name,
            parentID: .rootContainer
        )
    }

    public static func syntheticContainer(
        identifier: NSFileProviderItemIdentifier,
        name: String,
        parentID: NSFileProviderItemIdentifier = .rootContainer
    ) -> FileProviderItem {
        FileProviderItem(
            identifier: identifier,
            filename: name,
            parentID: parentID
        )
    }
}

// MARK: - NSFileProviderItemIdentifier + RemotePath

public extension NSFileProviderItemIdentifier {
    var remotePath: RemotePath {
        if self == .rootContainer {
            return .root
        }
        return RemotePath(rawValue)
    }
}
