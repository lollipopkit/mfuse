# Privacy Policy

Effective date: October 4, 2026

MFuse is an open-source macOS app that mounts remote storage (SFTP, Amazon S3, WebDAV, SMB, FTP, NFS, Google Drive, Dropbox, and OneDrive) in Finder. This policy explains what data MFuse accesses, how it is used, and where it is stored. The source code is available at [github.com/lollipopkit/mfuse](https://github.com/lollipopkit/mfuse), so every statement here can be checked against it.

## Summary

- MFuse runs entirely on your Mac. The developer operates no server that receives your files, credentials, or account information.
- MFuse contains no analytics, advertising, crash reporting, or tracking.
- Your data is sent only to the storage services you configure and, if you enable iCloud sync, to your own iCloud account.

## Data MFuse accesses

- **Connection settings** you enter, such as a connection name, host, port, username, bucket, or path.
- **Credentials**: passwords, private keys, access keys, and OAuth access and refresh tokens.
- **Remote files**: names, folder structure, metadata (size, dates, type), and contents of files on the storage you connect, as you browse and use them in Finder.
- **Account identity** for OAuth services (Google Drive, Dropbox, OneDrive): the account display name and email address, shown in MFuse to label the connection.

## Google user data

When you connect a Google Drive account, MFuse requests the following permission:

- `https://www.googleapis.com/auth/drive` — to list, read, create, modify, move, rename, and delete files in your Google Drive. MFuse performs these operations only in response to your actions in Finder or in MFuse, so that your Drive appears and behaves as a folder on your Mac.

MFuse also reads your Google account display name and email address through the Google Drive API, to show which account a connection belongs to.

Google user data is used only to provide this feature. In particular, MFuse:

- does not transfer Google user data to the developer or to any third party;
- does not use Google user data for advertising, and does not sell it;
- does not allow any person to read Google user data;
- does not use Google user data to develop, improve, or train generalized or non-personalized AI or machine-learning models.

MFuse's use and transfer of information received from Google APIs adheres to the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including the Limited Use requirements.

## Where data is stored

- **Credentials** are stored in the macOS Keychain.
- **Connection settings**, together with cached file metadata and cached file contents used to make Finder fast, are stored on your Mac in `~/Library/Group Containers/group.com.lollipopkit.mfuse.shared`.
- Files you open in Finder are also kept by macOS in its File Provider storage under `~/Library/CloudStorage`, as with other cloud storage apps.

## iCloud sync (optional)

iCloud sync is off by default. If you turn it on, MFuse syncs your connection settings through your iCloud Drive and your credentials through iCloud Keychain, so that the same connections are available on your other Macs. This data is handled by Apple under your Apple Account and Apple's privacy policy; the developer has no access to it. File contents are never synced through iCloud by MFuse.

## Data sharing

MFuse sends data only to the services you configure — for example Google, Dropbox, Microsoft, or your own servers — in order to carry out the operations you request, and to Apple if you enable iCloud sync. Cloud APIs are accessed over HTTPS. MFuse does not share data with anyone else.

## Retention and deletion

- Removing a connection in MFuse unmounts it and deletes its saved credentials, cached file metadata, and cached file contents. Files on the remote storage are not affected.
- You can revoke MFuse's access to your Google account at any time at [myaccount.google.com/connections](https://myaccount.google.com/connections).
- To delete all data MFuse keeps on your Mac, first remove every connection in MFuse, which deletes their credentials from the Keychain. Then quit MFuse and delete the folder `~/Library/Group Containers/group.com.lollipopkit.mfuse.shared`, or uninstall with `brew uninstall --zap --cask mfuse`. Neither of these last two steps removes Keychain credentials on its own.

## Children

MFuse is not directed at children under 13 and does not knowingly collect their data.

## Changes

Changes to this policy are published on this page with an updated effective date. The full history is in the project's Git repository.

## Contact

For questions about this policy, open an issue at [github.com/lollipopkit/mfuse/issues](https://github.com/lollipopkit/mfuse/issues).
