import XCTest
@testable import MFuseCore

/// Minimal backend used to verify registry wiring without touching a network.
private actor StubFileSystem: RemoteFileSystem {
    let config: ConnectionConfig

    init(config: ConnectionConfig) {
        self.config = config
    }

    var isConnected: Bool { false }
    func connect() async throws {}
    func disconnect() async throws {}
    func enumerate(at path: RemotePath) async throws -> [RemoteItem] { [] }
    func itemInfo(at path: RemotePath) async throws -> RemoteItem {
        throw RemoteFileSystemError.notFound(path)
    }
    func readFile(at path: RemotePath) async throws -> Data { Data() }
    func writeFile(at path: RemotePath, data: Data) async throws {}
    func createFile(at path: RemotePath, data: Data) async throws {}
    func createDirectory(at path: RemotePath) async throws {}
    func delete(at path: RemotePath) async throws {}
    func move(from source: RemotePath, to destination: RemotePath) async throws {}
}

final class BackendRegistryTests: XCTestCase {

    private func config(_ type: BackendType) -> ConnectionConfig {
        ConnectionConfig(
            name: "Test",
            backendType: type,
            host: "localhost",
            port: type.defaultPort,
            username: "user",
            authMethod: type.supportedAuthMethods.first ?? .password,
            remotePath: "/"
        )
    }

    func testRegisterAndCreate() async {
        // A dedicated instance rather than the shared singleton, whose contents depend on
        // whether a host app already registered its backends.
        let registry = BackendRegistry()
        XCTAssertFalse(registry.isSupported(.sftp))
        XCTAssertNil(registry.createFileSystem(config: config(.sftp), credential: Credential()))

        registry.register(.sftp) { config, _ in StubFileSystem(config: config) }

        XCTAssertTrue(registry.isSupported(.sftp))
        XCTAssertEqual(registry.supportedTypes, [.sftp])

        let created = registry.createFileSystem(config: config(.sftp), credential: Credential())
        XCTAssertTrue(created is StubFileSystem)
        // An unregistered type must still resolve to nil.
        XCTAssertNil(registry.createFileSystem(config: config(.s3), credential: Credential()))
    }

    func testIsSupported() {
        let registry = BackendRegistry.shared
        // We can't guarantee registrations in unit tests without the app target,
        // but the API should not crash
        _ = registry.isSupported(.sftp)
        _ = registry.isSupported(.s3)
    }

    func testCreateFileSystemForUnregisteredType() {
        // Create a fresh registry-like test
        // BackendRegistry.shared is a singleton, so we test nil return for un-registered types
        // by checking with a type that might not be registered in test context
        let config = ConnectionConfig(
            name: "Test",
            backendType: .nfs,
            host: "localhost",
            port: 2049,
            username: "user",
            authMethod: .anonymous,
            remotePath: "/"
        )
        // In test context without app registration, this may return nil
        let fs = BackendRegistry.shared.createFileSystem(config: config, credential: Credential())
        // We just verify no crash — fs may or may not be nil depending on test setup
        _ = fs
    }
}

final class BackendTypeTests: XCTestCase {

    func testAllCases() {
        XCTAssertEqual(
            Set(BackendType.allCases),
            [.sftp, .s3, .webdav, .smb, .nfs, .ftp, .googleDrive, .dropbox, .oneDrive]
        )
    }

    func testDisplayName() {
        XCTAssertEqual(BackendType.sftp.displayName, "SFTP")
        XCTAssertEqual(BackendType.s3.displayName, "S3")
        XCTAssertEqual(BackendType.webdav.displayName, "WebDAV")
        XCTAssertEqual(BackendType.smb.displayName, "SMB")
        XCTAssertEqual(BackendType.nfs.displayName, "NFS")
        XCTAssertEqual(BackendType.ftp.displayName, "FTP")
        XCTAssertEqual(BackendType.googleDrive.displayName, "Google Drive")
    }

    func testLocalizedDisplayNamesFromBundle() {
        XCTAssertEqual(
            MFuseCoreL10n.string(
                "backend.googleDrive",
                localeIdentifier: "zh-CN",
                fallback: "Google Drive"
            ),
            "Google 云端硬盘"
        )
        XCTAssertEqual(
            MFuseCoreL10n.string(
                "backend.googleDrive",
                localeIdentifier: "fr",
                fallback: "Google Drive"
            ),
            "Google Drive"
        )
    }

    /// The package ships `zh-Hans` and `zh-Hant` and nothing else for Chinese, so every
    /// regional identifier has to resolve to one of the two scripts. Listing the Simplified
    /// regions left the ones nobody enumerated — `zh-MY` above all — on the English
    /// fallback.
    func testRegionalChineseResolvesToAShippedScript() {
        let simplified = ["zh-MY", "zh-SG", "zh-CN", "zh_CN", "zh-Hans-SG", "zh"]
        for identifier in simplified {
            XCTAssertEqual(
                MFuseCoreL10n.string(
                    "backend.googleDrive",
                    localeIdentifier: identifier,
                    fallback: "unlocalized"
                ),
                "Google 云端硬盘",
                "\(identifier) should read the Simplified Chinese resources"
            )
        }

        for identifier in ["zh-TW", "zh-HK", "zh-MO", "zh-Hant-MY"] {
            XCTAssertEqual(
                MFuseCoreL10n.string(
                    "backend.googleDrive",
                    localeIdentifier: identifier,
                    fallback: "unlocalized"
                ),
                "Google 雲端硬碟",
                "\(identifier) should read the Traditional Chinese resources"
            )
        }
    }

    /// The fallbacks here deliberately differ from the expected values so a missing
    /// resource key fails the assertion instead of silently degrading to the fallback.
    ///
    /// Every locale asserts the actual value, including Google Drive's two translated
    /// names — checking only for presence would let a wrong provider name through.
    func testEveryBackendHasLocalizedDisplayNameResource() {
        let locales = ["en", "es", "fr", "id", "it", "ja", "ko", "zh-Hans", "zh-Hant"]
        let translatedGoogleDrive = [
            "zh-Hans": "Google 云端硬盘",
            "zh-Hant": "Google 雲端硬碟"
        ]

        for localeIdentifier in locales {
            let expectedByKey = [
                "backend.googleDrive": translatedGoogleDrive[localeIdentifier] ?? "Google Drive",
                "backend.dropbox": "Dropbox",
                "backend.oneDrive": "OneDrive"
            ]
            for (key, expected) in expectedByKey {
                let value = MFuseCoreL10n.string(
                    key,
                    localeIdentifier: localeIdentifier,
                    fallback: "<missing>"
                )
                XCTAssertNotEqual(value, "<missing>", "\(key) is missing from \(localeIdentifier).lproj")
                XCTAssertEqual(value, expected, "\(key) in \(localeIdentifier).lproj")
            }
        }
    }

    /// Every key of every catalog, not the handful the other tests name.
    ///
    /// The spot checks above cover what their assertions spell out; a key nobody listed —
    /// `mount.error.mountFailed`, say — could be deleted from one locale, or have its
    /// `%@` turned into `%d`, and the suite would stay green. The base locale is the
    /// contract: every other bundle must carry the same keys with the same argument
    /// signature, since `String(format:)` reads them positionally at runtime.
    func testEveryLocalizedKeyMatchesTheBaseLocaleSignature() throws {
        let baseLocale = "en"
        let otherLocales = ["es", "fr", "id", "it", "ja", "ko", "zh-Hans", "zh-Hant"]
        let baseStrings = try localizedStrings(for: baseLocale)
        XCTAssertFalse(baseStrings.isEmpty, "the \(baseLocale) catalog is empty")

        // The base locale is held to the same contract it defines. It is not just another
        // bundle: an empty value here ships as the English string *and* becomes the
        // signature every other locale is measured against, so nothing downstream would
        // report it.
        for (key, template) in baseStrings {
            XCTAssertFalse(
                template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(key) is empty for \(baseLocale)"
            )
            assertNoMalformedFormatSpecifier(in: template, key: key, locale: baseLocale)
        }

        for locale in otherLocales {
            let strings = try localizedStrings(for: locale)
            let missing = Set(baseStrings.keys).subtracting(strings.keys).sorted()
            XCTAssertTrue(missing.isEmpty, "\(locale).lproj is missing: \(missing.joined(separator: ", "))")
            let extra = Set(strings.keys).subtracting(baseStrings.keys).sorted()
            XCTAssertTrue(extra.isEmpty, "\(locale).lproj has keys the base locale does not: \(extra.joined(separator: ", "))")

            for (key, template) in strings {
                guard let baseTemplate = baseStrings[key] else { continue }
                XCTAssertFalse(
                    template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "\(key) is empty for \(locale)"
                )
                assertNoMalformedFormatSpecifier(in: template, key: key, locale: locale)
                assertFormatSpecifiers(
                    in: template,
                    expectedCount: formatSpecifiers(in: baseTemplate).count,
                    key: key,
                    locale: locale
                )
            }
        }
    }

    private func localizedStrings(for locale: String) throws -> [String: String] {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "Localizable",
                withExtension: "strings",
                subdirectory: nil,
                localization: locale
            ),
            "no Localizable.strings for \(locale)"
        )
        return try XCTUnwrap(
            NSDictionary(contentsOf: url) as? [String: String],
            "\(locale).lproj/Localizable.strings is not a string catalog"
        )
    }

    func testDefaultPort() {
        XCTAssertEqual(BackendType.sftp.defaultPort, 22)
        XCTAssertEqual(BackendType.s3.defaultPort, 443)
        XCTAssertEqual(BackendType.webdav.defaultPort, 443)
        XCTAssertEqual(BackendType.smb.defaultPort, 445)
        XCTAssertEqual(BackendType.nfs.defaultPort, 2049)
        XCTAssertEqual(BackendType.ftp.defaultPort, 21)
        XCTAssertEqual(BackendType.googleDrive.defaultPort, 443)
        XCTAssertEqual(BackendType.dropbox.defaultPort, 443)
        XCTAssertEqual(BackendType.oneDrive.defaultPort, 443)
    }

    func testIconName() {
        for type in BackendType.allCases {
            XCTAssertFalse(type.iconName.isEmpty, "\(type) should have an icon name")
        }
    }

    func testSupportedAuthMethods() {
        XCTAssertTrue(BackendType.sftp.supportedAuthMethods.contains(.password))
        XCTAssertTrue(BackendType.sftp.supportedAuthMethods.contains(.publicKey))
        XCTAssertTrue(BackendType.s3.supportedAuthMethods.contains(.accessKey))
        XCTAssertTrue(BackendType.googleDrive.supportedAuthMethods.contains(.oauth))
        XCTAssertTrue(BackendType.ftp.supportedAuthMethods.contains(.anonymous))

        for type in BackendType.allCases {
            XCTAssertFalse(type.supportedAuthMethods.isEmpty, "\(type) should have at least one auth method")
        }
    }

    func testCodableRoundTrip() throws {
        for type in BackendType.allCases {
            let data = try JSONEncoder().encode(type)
            let decoded = try JSONDecoder().decode(BackendType.self, from: data)
            XCTAssertEqual(type, decoded)
        }
    }

    func testIdentifiable() {
        for type in BackendType.allCases {
            XCTAssertEqual(type.id, type.rawValue)
        }
    }

    func testAuthMethodDisplayNameUsesLocalizationResources() {
        XCTAssertEqual(
            AuthMethod.password.displayName,
            MFuseCoreL10n.string(
                "auth.password",
                localeIdentifier: "en",
                fallback: "Password"
            )
        )
        XCTAssertEqual(
            MFuseCoreL10n.string(
                "auth.publicKey",
                localeIdentifier: "zh-CN",
                fallback: "Public Key"
            ),
            "公钥"
        )
    }

    func testConnectionAndMountStatusFormatting() {
        XCTAssertEqual(
            MFuseCoreL10n.string(
                "connection.error",
                localeIdentifier: "en",
                fallback: "Error: %@",
                "boom"
            ),
            "Error: boom"
        )
        XCTAssertEqual(
            MFuseCoreL10n.string(
                "mount.error.status",
                localeIdentifier: "zh-CN",
                fallback: "Mount error: %@",
                "失败"
            ),
            "挂载错误：失败"
        )
    }

    /// The connection lifecycle messages are the only report of a failed removal or
    /// rollback, so a locale missing one — or dropping a positional placeholder — would
    /// leave the user with an unusable error.
    func testConnectionManagerErrorResourcesExistInEveryLocale() {
        let placeholderCounts = [
            "connectionManager.error.cleanupFailed": 1,
            "connectionManager.error.restoreRemovedConnection": 1,
            "connectionManager.error.restoreCredential": 1,
            "connectionManager.error.restoreRegistration": 1,
            "connectionManager.error.removeWithRestoreFailures": 3,
            "connectionManager.error.deleteCredentialWithRestoreFailures": 3,
            "connectionManager.error.deleteCredentialRecovered": 2,
            "connectionManager.error.unsupportedBackend": 1,
            "connectionManager.error.removalInProgress": 1,
            "connectionManager.error.connectionNotFound": 1,
            "connectionManager.error.revisionConflict": 1,
            "connectionManager.error.reregisterChangedConnection": 2
        ]
        let locales = ["en", "es", "fr", "id", "it", "ja", "ko", "zh-Hans", "zh-Hant"]

        for locale in locales {
            for (key, expectedPlaceholders) in placeholderCounts {
                let sentinel = "<missing>"
                let template = MFuseCoreL10n.string(key, localeIdentifier: locale, fallback: sentinel)
                XCTAssertNotEqual(template, sentinel, "\(key) is missing for \(locale)")
                XCTAssertFalse(template.isEmpty, "\(key) is empty for \(locale)")
                assertFormatSpecifiers(
                    in: template,
                    expectedCount: expectedPlaceholders,
                    key: key,
                    locale: locale
                )
            }
        }
    }

    /// Counting `%` says nothing about which argument ends up where: a translation that
    /// writes `%1$@` twice, renumbers the arguments, or swaps `%@` for `%d` still passes
    /// a count check and then drops — or misreads — an argument at runtime.
    /// The format specifiers of a template, in order: `(position, conversion)`, where
    /// `position` is nil for an unnumbered `%@`.
    private func formatSpecifiers(in template: String) -> [(position: Int?, conversion: String)] {
        // `%%` is an escaped percent, not a placeholder, so it is consumed first.
        let pattern = try! NSRegularExpression(pattern: "%%|%(?:(\\d+)\\$)?([@a-zA-Z])")
        let range = NSRange(template.startIndex..<template.endIndex, in: template)
        return pattern.matches(in: template, range: range).compactMap { match in
            guard let conversionRange = Range(match.range(at: 2), in: template) else {
                return nil
            }
            let position = Range(match.range(at: 1), in: template).flatMap { Int(template[$0]) }
            return (position: position, conversion: String(template[conversionRange]))
        }
    }

    /// Fail on a `%` that begins neither an escaped percent nor a placeholder.
    ///
    /// The scanner above skips them by construction — it only matches what is well formed
    /// — so a translation ending in a bare `%`, or writing `%s` where the argument is an
    /// object, passes every count and position check and then misreads memory at runtime.
    /// The escape is consumed first, so the second half of a `%%` is not mistaken for one.
    private func assertNoMalformedFormatSpecifier(
        in template: String,
        key: String,
        locale: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let pattern = try! NSRegularExpression(pattern: "%%|%(?:\\d+\\$)?[@a-zA-Z]|(%)")
        let range = NSRange(template.startIndex..<template.endIndex, in: template)
        let malformed = pattern.matches(in: template, range: range).contains { match in
            match.range(at: 1).location != NSNotFound
        }
        XCTAssertFalse(
            malformed,
            "\(key) has a stray or dangling % for \(locale)",
            file: file,
            line: line
        )
    }

    private func assertFormatSpecifiers(
        in template: String,
        expectedCount: Int,
        key: String,
        locale: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let specifiers = formatSpecifiers(in: template)

        XCTAssertEqual(
            specifiers.count,
            expectedCount,
            "\(key) has the wrong number of placeholders for \(locale)",
            file: file,
            line: line
        )

        var positions: [Int] = []
        for (offset, specifier) in specifiers.enumerated() {
            XCTAssertEqual(
                specifier.conversion,
                "@",
                "\(key) uses %\(specifier.conversion) instead of a string placeholder for \(locale)",
                file: file,
                line: line
            )
            if let position = specifier.position {
                positions.append(position)
            } else {
                // An unnumbered placeholder consumes arguments in order, which is only
                // unambiguous when it is the sole one.
                positions.append(offset + 1)
                XCTAssertEqual(
                    expectedCount,
                    1,
                    "\(key) mixes unnumbered placeholders into a multi-argument template for \(locale)",
                    file: file,
                    line: line
                )
            }
        }

        XCTAssertEqual(
            positions.sorted(),
            expectedCount == 0 ? [] : Array(1...expectedCount),
            "\(key) does not map each argument exactly once for \(locale)",
            file: file,
            line: line
        )
    }

    /// `zh-TW` is what a Traditional Chinese Mac actually reports, and it has no bundle of
    /// its own: it has to resolve through the `zh-Hant` candidate fallback rather than
    /// silently landing on Simplified Chinese.
    func testTraditionalChineseLocaleIdentifierResolvesToTheHantResources() {
        let simplified = MFuseCoreL10n.string(
            "auth.publicKey",
            localeIdentifier: "zh-Hans",
            fallback: "Public Key"
        )
        let traditional = MFuseCoreL10n.string(
            "auth.publicKey",
            localeIdentifier: "zh-Hant",
            fallback: "Public Key"
        )
        XCTAssertNotEqual(traditional, simplified)

        XCTAssertEqual(
            MFuseCoreL10n.string(
                "auth.publicKey",
                localeIdentifier: "zh-TW",
                fallback: "Public Key"
            ),
            traditional,
            "zh-TW did not resolve to the Traditional Chinese resources"
        )
        XCTAssertEqual(
            MFuseCoreL10n.string(
                "mount.error.status",
                localeIdentifier: "zh-TW",
                fallback: "Mount error: %@",
                "失敗"
            ),
            MFuseCoreL10n.string(
                "mount.error.status",
                localeIdentifier: "zh-Hant",
                fallback: "Mount error: %@",
                "失敗"
            )
        )

        // Hong Kong and Macau are Traditional too, and an underscored or script-tagged
        // identifier is the same locale — each one used to fall through to bare `zh`,
        // which is not shipped, and land on the English fallback.
        for identifier in ["zh-HK", "zh-MO", "zh_TW", "zh-Hant-HK"] {
            XCTAssertEqual(
                MFuseCoreL10n.string(
                    "auth.publicKey",
                    localeIdentifier: identifier,
                    fallback: "Public Key"
                ),
                traditional,
                "\(identifier) did not resolve to the Traditional Chinese resources"
            )
        }

        // Simplified keeps its own regional and script-tagged forms.
        for identifier in ["zh_CN", "zh-SG", "zh-Hans-CN"] {
            XCTAssertEqual(
                MFuseCoreL10n.string(
                    "auth.publicKey",
                    localeIdentifier: identifier,
                    fallback: "Public Key"
                ),
                simplified,
                "\(identifier) did not resolve to the Simplified Chinese resources"
            )
        }
    }

    func testLocalizedErrorsAreNonEmpty() {
        XCTAssertFalse(RemoteFileSystemError.notConnected.localizedDescription.isEmpty)
        XCTAssertFalse(MountError.extensionNotEnabled.localizedDescription.isEmpty)
        XCTAssertFalse(ConnectionManagerError.cleanupFailed(UUID()).localizedDescription.isEmpty)
    }
}

final class ConnectionConfigDisplayAddressTests: XCTestCase {

    private func config(
        _ type: BackendType,
        host: String = "",
        port: UInt16? = nil,
        parameters: [String: String] = [:]
    ) -> ConnectionConfig {
        ConnectionConfig(
            name: "Test",
            backendType: type,
            host: host,
            port: port ?? type.defaultPort,
            username: "user",
            authMethod: type.supportedAuthMethods.first ?? .password,
            remotePath: "/",
            parameters: parameters
        )
    }

    /// Regression: the sidebar rendered "\(host):\(port)" through SwiftUI's localized
    /// string interpolation, which formatted 9000 as "9,000".
    func testNonDefaultPortIsRenderedWithoutGroupingSeparator() {
        let address = config(.sftp, host: "localhost", port: 2222).displayAddress
        XCTAssertEqual(address, "localhost:2222")
        XCTAssertFalse(address.contains(","))
    }

    func testDefaultPortIsOmitted() {
        XCTAssertEqual(config(.sftp, host: "example.com", port: 22).displayAddress, "example.com")
    }

    /// A stored host of pure whitespace is nothing to show, so it must fall back like an
    /// empty one instead of rendering blanks or a bare ":2222".
    func testBlankHostFallsBackToTheBackendName() {
        XCTAssertEqual(config(.sftp, host: "   ").displayAddress, BackendType.sftp.displayName)
        XCTAssertEqual(
            config(.sftp, host: "   ", port: 2222).displayAddress,
            BackendType.sftp.displayName
        )
        XCTAssertEqual(config(.sftp, host: "  example.com  ").displayAddress, "example.com")
    }

    /// An IPv6 literal is all colons, so the port has to be told apart with brackets.
    func testIPv6HostIsBracketedBeforeThePort() {
        XCTAssertEqual(config(.sftp, host: "2001:db8::1", port: 2222).displayAddress, "[2001:db8::1]:2222")
        XCTAssertEqual(config(.sftp, host: "[2001:db8::1]", port: 2222).displayAddress, "[2001:db8::1]:2222")
        XCTAssertEqual(config(.sftp, host: "2001:db8::1", port: 22).displayAddress, "2001:db8::1")
    }

    /// Regression: S3 has no host, so the sidebar used to show a bare ":9,000".
    func testS3FallsBackToEndpointThenBucket() {
        // Two buckets on one endpoint are two different mounts, so the bucket belongs in
        // the address that identifies the row.
        XCTAssertEqual(
            config(.s3, parameters: ["endpoint": "http://localhost:9000", "bucket": "b"]).displayAddress,
            "http://localhost:9000/b"
        )
        XCTAssertEqual(
            config(.s3, parameters: ["endpoint": "http://localhost:9000/", "bucket": "b"]).displayAddress,
            "http://localhost:9000/b"
        )
        XCTAssertNotEqual(
            config(.s3, parameters: ["endpoint": "http://localhost:9000", "bucket": "b"]).displaySubtitle,
            config(.s3, parameters: ["endpoint": "http://localhost:9000", "bucket": "other"]).displaySubtitle
        )
        XCTAssertEqual(config(.s3, parameters: ["bucket": "my-bucket"]).displayAddress, "my-bucket")
        XCTAssertEqual(config(.s3).displayAddress, BackendType.s3.displayName)
    }

    /// What is displayed must match what the backend connects to, including for configs
    /// that still carry the port outside the endpoint.
    func testS3DisplayAddressShowsTheEffectiveEndpoint() {
        XCTAssertEqual(
            config(.s3, port: 9000, parameters: ["endpoint": "http://localhost"]).displayAddress,
            "http://localhost:9000"
        )
        XCTAssertEqual(
            config(
                .s3,
                port: 9000,
                parameters: ["endpoint": "http://localhost", "bucket": "b"]
            ).displayAddress,
            "http://localhost:9000/b"
        )
    }

    /// The legacy shim folds a hidden port into the endpoint, so a config that has merely
    /// been through the editor's normalization addresses the same server as the one it
    /// replaced. Reading the raw pair called that a different server and left a working
    /// mount down for nothing.
    func testS3AddressesSameServerAcrossThePortNormalization() {
        let legacy = config(.s3, port: 9000, parameters: ["endpoint": "http://localhost", "bucket": "b"])
        let normalized = config(.s3, port: 443, parameters: ["endpoint": "http://localhost:9000", "bucket": "b"])

        XCTAssertTrue(legacy.addressesSameServer(as: normalized))
        XCTAssertTrue(normalized.addressesSameServer(as: legacy))

        // Written differently, resolved the same: the editor omits a default region and a
        // false path-style flag, and a legacy or synced config may spell both out.
        let spelledOut = config(
            .s3,
            port: 443,
            parameters: [
                "endpoint": "http://localhost:9000",
                "bucket": "b",
                "region": "us-east-1",
                "pathStyle": "false"
            ]
        )
        XCTAssertTrue(normalized.addressesSameServer(as: spelledOut))
        XCTAssertTrue(spelledOut.addressesSameServer(as: normalized))

        // A real move is still a move.
        let elsewhere = config(.s3, port: 443, parameters: ["endpoint": "http://elsewhere:9000", "bucket": "b"])
        XCTAssertFalse(normalized.addressesSameServer(as: elsewhere))
        let otherBucket = config(.s3, port: 443, parameters: ["endpoint": "http://localhost:9000", "bucket": "other"])
        XCTAssertFalse(normalized.addressesSameServer(as: otherBucket))
        let otherRegion = config(
            .s3,
            port: 443,
            parameters: ["endpoint": "http://localhost:9000", "bucket": "b", "region": "eu-west-1"]
        )
        XCTAssertFalse(normalized.addressesSameServer(as: otherRegion))
        let pathStyle = config(
            .s3,
            port: 443,
            parameters: ["endpoint": "http://localhost:9000", "bucket": "b", "pathStyle": "true"]
        )
        XCTAssertFalse(normalized.addressesSameServer(as: pathStyle))
    }

    /// S3 addresses by endpoint and the account backends by their token: neither is handed
    /// a host, a port or a username. A value an older build left in one of those fields is
    /// therefore not part of the address, and comparing it anyway made the save that
    /// normalizes it away read as a move to another server — which took the mount down and
    /// then withheld the credential it needed to come back up.
    func testFieldsTheBackendDoesNotAddressByAreNotAnIdentityChange() {
        func config(
            _ type: BackendType,
            host: String,
            port: UInt16,
            username: String,
            authMethod: AuthMethod,
            parameters: [String: String]
        ) -> ConnectionConfig {
            ConnectionConfig(
                name: "Test",
                backendType: type,
                host: host,
                port: port,
                username: username,
                authMethod: authMethod,
                remotePath: "/",
                parameters: parameters
            )
        }

        // The port is left alone here: S3's legacy shim folds it into the endpoint, so for
        // that backend it carries the address rather than noise. See
        // `testS3AddressesSameServerAcrossThePortNormalization`.
        let s3Parameters = ["endpoint": "https://s3.example.com", "bucket": "b"]
        let legacyS3 = config(
            .s3,
            host: "s3.example.com",
            port: BackendType.s3.defaultPort,
            username: "stale",
            authMethod: .accessKey,
            parameters: s3Parameters
        )
        let normalizedS3 = config(
            .s3,
            host: "",
            port: BackendType.s3.defaultPort,
            username: "",
            authMethod: .accessKey,
            parameters: s3Parameters
        )
        XCTAssertTrue(legacyS3.addressesSameServer(as: normalizedS3))
        XCTAssertTrue(normalizedS3.addressesSameServer(as: legacyS3))

        let account = ["oauthAccountName": "someone@example.com"]
        let legacyDropbox = config(
            .dropbox,
            host: "api.dropboxapi.com",
            port: 8443,
            username: "stale",
            authMethod: .oauth,
            parameters: account
        )
        let normalizedDropbox = config(
            .dropbox,
            host: "",
            port: BackendType.dropbox.defaultPort,
            username: "",
            authMethod: .oauth,
            parameters: account
        )
        XCTAssertTrue(legacyDropbox.addressesSameServer(as: normalizedDropbox))
        XCTAssertTrue(normalizedDropbox.addressesSameServer(as: legacyDropbox))

        // What the config does carry of the account identity still counts.
        let otherAccount = config(
            .dropbox,
            host: "",
            port: BackendType.dropbox.defaultPort,
            username: "",
            authMethod: .oauth,
            parameters: ["oauthAccountName": "someone.else@example.com"]
        )
        XCTAssertFalse(normalizedDropbox.addressesSameServer(as: otherAccount))
    }

    /// Regression: requests are signed for the region, and the editor stores the Region
    /// field as typed — so a stray space, or a field the user emptied, reached Soto as a
    /// region that does not exist.
    func testS3RegionIsTrimmedAndBlankReadsAsTheDefault() {
        XCTAssertEqual(config(.s3, parameters: ["region": " eu-west-1 "]).s3Region, "eu-west-1")
        XCTAssertEqual(config(.s3, parameters: ["region": ""]).s3Region, ConnectionConfig.defaultS3Region)
        XCTAssertEqual(config(.s3, parameters: ["region": "   "]).s3Region, ConnectionConfig.defaultS3Region)
        XCTAssertEqual(config(.s3).s3Region, ConnectionConfig.defaultS3Region)
        XCTAssertEqual(config(.s3, parameters: ["region": "eu-west-1"]).s3Region, "eu-west-1")

        // And so the whitespace is not a move to another server either.
        let padded = config(.s3, parameters: ["bucket": "b", "region": " eu-west-1 "])
        let trimmed = config(.s3, parameters: ["bucket": "b", "region": "eu-west-1"])
        XCTAssertTrue(padded.addressesSameServer(as: trimmed))
        XCTAssertTrue(trimmed.addressesSameServer(as: padded))
        XCTAssertFalse(trimmed.addressesSameServer(as: config(.s3, parameters: ["bucket": "b", "region": "eu-west-2"])))
    }

    /// A port that only repeats the scheme's default is not part of the endpoint, so
    /// writing it out either way addresses one server.
    func testS3AddressesSameServerAcrossADefaultPortInTheEndpoint() {
        let httpBare = config(.s3, parameters: ["endpoint": "http://minio.internal", "bucket": "b"])
        let httpSpelledOut = config(.s3, parameters: ["endpoint": "http://minio.internal:80", "bucket": "b"])
        XCTAssertTrue(httpBare.addressesSameServer(as: httpSpelledOut))
        XCTAssertTrue(httpSpelledOut.addressesSameServer(as: httpBare))

        let httpsBare = config(.s3, parameters: ["endpoint": "https://s3.example.com", "bucket": "b"])
        let httpsSpelledOut = config(.s3, parameters: ["endpoint": "https://s3.example.com:443", "bucket": "b"])
        XCTAssertTrue(httpsBare.addressesSameServer(as: httpsSpelledOut))
        XCTAssertTrue(httpsSpelledOut.addressesSameServer(as: httpsBare))

        // A port that is not the scheme's default is the address, and so is the scheme.
        let otherPort = config(.s3, parameters: ["endpoint": "https://s3.example.com:8443", "bucket": "b"])
        XCTAssertFalse(httpsBare.addressesSameServer(as: otherPort))
        let plaintext = config(.s3, parameters: ["endpoint": "http://s3.example.com", "bucket": "b"])
        XCTAssertFalse(httpsBare.addressesSameServer(as: plaintext))
        // 443 is http's address just as much as 8443 is.
        XCTAssertFalse(plaintext.addressesSameServer(as: httpsSpelledOut))
    }

    /// Regression: an anonymous login sends no username — FTP sends a fixed
    /// `USER anonymous` and WebDAV omits the Authorization header — and the editor saves
    /// the field empty. Comparing a legacy value left in it read as a move to another
    /// server, which took a working mount down and then withheld the remount.
    func testAnonymousUsernameIsNotAnIdentityChange() {
        func config(_ type: BackendType, username: String, authMethod: AuthMethod) -> ConnectionConfig {
            ConnectionConfig(
                name: "Test",
                backendType: type,
                host: "example.com",
                port: type.defaultPort,
                username: username,
                authMethod: authMethod,
                remotePath: "/"
            )
        }

        for type in [BackendType.ftp, .webdav] {
            let legacy = config(type, username: "old", authMethod: .anonymous)
            let normalized = config(type, username: "", authMethod: .anonymous)
            XCTAssertTrue(legacy.addressesSameServer(as: normalized), "\(type)")
            XCTAssertTrue(normalized.addressesSameServer(as: legacy), "\(type)")

            // The username is still the identity wherever the backend sends it.
            let named = config(type, username: "alice", authMethod: .password)
            XCTAssertFalse(named.addressesSameServer(as: config(type, username: "bob", authMethod: .password)), "\(type)")
            // Dropping the password for anonymous access is a different identity too.
            XCTAssertFalse(named.addressesSameServer(as: normalized), "\(type)")
        }

        // A method the backend never offers is not an anonymous login: SFTP sends the
        // username whatever the stored method says.
        let sftp = config(.sftp, username: "alice", authMethod: .anonymous)
        XCTAssertFalse(sftp.addressesSameServer(as: config(.sftp, username: "bob", authMethod: .anonymous)))
    }

    /// Everything that is not S3 is addressed by host and port, so those still count.
    func testHostBasedAddressesSameServerComparesPort() {
        let base = config(.sftp, host: "example.com", port: 22)
        XCTAssertTrue(base.addressesSameServer(as: config(.sftp, host: "example.com", port: 22)))
        XCTAssertFalse(base.addressesSameServer(as: config(.sftp, host: "example.com", port: 2222)))
        XCTAssertFalse(base.addressesSameServer(as: config(.sftp, host: "elsewhere.com", port: 22)))
    }

    func testS3EndpointAppliesConfiguredPortOnlyWhenItAddsInformation() {
        XCTAssertEqual(
            ConnectionConfig.s3Endpoint("http://localhost", applyingConfiguredPort: 9000),
            "http://localhost:9000"
        )
        XCTAssertEqual(
            ConnectionConfig.s3Endpoint("http://localhost:9000", applyingConfiguredPort: 443),
            "http://localhost:9000"
        )
        XCTAssertEqual(
            ConnectionConfig.s3Endpoint("https://s3.amazonaws.com", applyingConfiguredPort: 443),
            "https://s3.amazonaws.com"
        )
        XCTAssertEqual(
            ConnectionConfig.s3Endpoint("http://minio.internal", applyingConfiguredPort: 80),
            "http://minio.internal"
        )
        // Regression: a new S3 config keeps the backend default port because the editor
        // no longer offers the field, so it must not be written onto a plain-HTTP endpoint.
        XCTAssertEqual(
            ConnectionConfig.s3Endpoint(
                "http://localhost",
                applyingConfiguredPort: BackendType.s3.defaultPort
            ),
            "http://localhost"
        )
        XCTAssertEqual(
            ConnectionConfig.s3Endpoint("not a url", applyingConfiguredPort: 9000),
            "not a url"
        )
    }

    func testOAuthBackendsShowAccountInsteadOfEmptyHost() {
        XCTAssertEqual(
            config(.dropbox, parameters: ["oauthAccountEmail": "a@b.com"]).displayAddress,
            "a@b.com"
        )
        XCTAssertEqual(config(.oneDrive).displayAddress, BackendType.oneDrive.displayName)
    }

    func testNoBackendRendersEmptyOrBareColon() {
        for type in BackendType.allCases {
            let address = config(type).displayAddress
            XCTAssertFalse(address.isEmpty, "\(type) should have a display address")
            XCTAssertFalse(address.hasPrefix(":"), "\(type) rendered a bare port")
        }
    }
}

final class ConnectionConfigSubtitleTests: XCTestCase {

    private func config(_ type: BackendType, host: String = "", parameters: [String: String] = [:]) -> ConnectionConfig {
        ConnectionConfig(
            name: "Test",
            backendType: type,
            host: host,
            port: type.defaultPort,
            username: "user",
            authMethod: type.supportedAuthMethods.first ?? .password,
            remotePath: "/",
            parameters: parameters
        )
    }

    func testSubtitleCombinesTypeAndAddress() {
        XCTAssertEqual(config(.sftp, host: "example.com").displaySubtitle, "SFTP · example.com")
    }

    /// The type must not be printed twice when displayAddress already fell back to it.
    func testSubtitleDoesNotRepeatTypeWhenAddressIsUnknown() {
        XCTAssertEqual(config(.dropbox).displaySubtitle, BackendType.dropbox.displayName)
        XCTAssertEqual(config(.s3).displaySubtitle, BackendType.s3.displayName)
    }
}
