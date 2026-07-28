import Darwin
import Foundation

enum ProfileStore {
  private static let directoryName = "SBM"
  private static let fileName = "profiles.json"

  static func loadProfileLibrary() -> ProfileLibrary? {
    guard let url = try? storageURL(),
      isSecureDirectory(url.deletingLastPathComponent()),
      isSecureRegularFile(url),
      let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
    else { return nil }
    return try? JSONDecoder().decode(ProfileLibrary.self, from: data)
  }

  static func saveProfileLibrary(_ library: ProfileLibrary) throws {
    let url = try storageURL(createDirectory: true)
    try saveProfileLibrary(library, to: url)
  }

  static func saveProfileLibrary(_ library: ProfileLibrary, to url: URL) throws {
    try requireSecureDirectory(url.deletingLastPathComponent())
    if FileManager.default.fileExists(atPath: url.path) {
      try requireSecureRegularFile(url)
    }
    let data = try JSONEncoder().encode(library)
    let temporaryURL = url.deletingLastPathComponent()
      .appendingPathComponent(".profiles-\(UUID().uuidString).tmp")
    defer { try? FileManager.default.removeItem(at: temporaryURL) }
    guard
      FileManager.default.createFile(
        atPath: temporaryURL.path,
        contents: data,
        attributes: [.posixPermissions: 0o600]
      )
    else {
      throw CocoaError(.fileWriteUnknown)
    }
    if FileManager.default.fileExists(atPath: url.path) {
      _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
    } else {
      try FileManager.default.moveItem(at: temporaryURL, to: url)
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: url.path
    )
  }

  private static func storageURL(createDirectory: Bool = false) throws -> URL {
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: createDirectory
    )
    let directory = base.appendingPathComponent(directoryName, isDirectory: true)
    if createDirectory {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: directory.path
      )
      try requireSecureDirectory(directory)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      var mutableDirectory = directory
      try mutableDirectory.setResourceValues(values)
    }
    return directory.appendingPathComponent(fileName)
  }

  private static func requireSecureDirectory(_ url: URL) throws {
    guard isSecureDirectory(url) else {
      throw CocoaError(.fileWriteNoPermission)
    }
  }

  private static func requireSecureRegularFile(_ url: URL) throws {
    guard isSecureRegularFile(url) else {
      throw CocoaError(.fileWriteNoPermission)
    }
  }

  private static func isSecureDirectory(_ url: URL) -> Bool {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return false }
    return (info.st_mode & S_IFMT) == S_IFDIR
      && info.st_uid == getuid()
      && (info.st_mode & 0o077) == 0
  }

  private static func isSecureRegularFile(_ url: URL) -> Bool {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return false }
    return (info.st_mode & S_IFMT) == S_IFREG
      && info.st_uid == getuid()
      && (info.st_mode & 0o077) == 0
  }
}
