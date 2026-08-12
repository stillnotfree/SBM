import Darwin
import Foundation

enum ProfileStore {
  private static let directoryName = "SBM"
  private static let fileName = "profiles.json"
  private static let maximumFileSize = 8 * 1_048_576

  static func loadProfileLibrary() throws -> ProfileLibrary? {
    try loadProfileLibrary(from: storageURL(), preserveInvalidCopy: true)
  }

  static func loadProfileLibrary(
    from url: URL,
    preserveInvalidCopy: Bool = false
  ) throws -> ProfileLibrary? {
    guard pathExistsWithoutFollowingSymlinks(url) else {
      if errno == ENOENT { return nil }
      throw ProfileStoreFailure.unreadable
    }
    guard isSecureDirectory(url.deletingLastPathComponent()) else {
      throw ProfileStoreFailure.unsafeStorage
    }
    let data: Data
    do {
      data = try readRegularFileWithoutFollowingSymlinks(url, requireSecureMode: true)
    } catch let failure as ProfileStoreFailure {
      throw failure
    } catch {
      throw ProfileStoreFailure.unreadable
    }
    var library: ProfileLibrary
    do {
      library = try JSONDecoder().decode(ProfileLibrary.self, from: data)
    } catch {
      let preservedName = preserveInvalidCopy ? try preserveInvalid(data, nextTo: url) : nil
      throw ProfileStoreFailure.invalidJSON(preservedName)
    }
    if library.requiresMigration {
      // Do not allow an auto-refresh or helper request to observe a transient
      // legacy schema: atomically persist stable IDs first. A write failure is
      // deliberately propagated as such; valid legacy data is not quarantined.
      library.requiresMigration = false
      try saveProfileLibrary(library, to: url)
    }
    return library
  }

  static func saveProfileLibrary(_ library: ProfileLibrary) throws {
    let url = try storageURL(createDirectory: true)
    try saveProfileLibrary(library, to: url)
  }

  static func importProfileLibrary(from sourceURL: URL) throws -> ProfileLibrary {
    let destinationURL = try storageURL(createDirectory: true)
    return try importProfileLibrary(from: sourceURL, to: destinationURL)
  }

  static func importProfileLibrary(
    from sourceURL: URL,
    to destinationURL: URL
  ) throws -> ProfileLibrary {
    var library = try decodeImportedProfileLibrary(from: sourceURL)
    library.requiresMigration = false
    try saveProfileLibrary(library, to: destinationURL)
    return library
  }

  static func resetProfileLibrary() throws -> ProfileLibrary {
    let url = try storageURL(createDirectory: true)
    return try resetProfileLibrary(at: url)
  }

  static func resetProfileLibrary(at url: URL) throws -> ProfileLibrary {
    try requireSecureDirectory(url.deletingLastPathComponent())
    if pathExistsWithoutFollowingSymlinks(url) {
      let original = try readRegularFileWithoutFollowingSymlinks(
        url,
        requireSecureMode: true
      )
      _ = try preserveInvalid(original, nextTo: url)
    }
    let empty = ProfileLibrary.empty
    try saveProfileLibrary(empty, to: url)
    return empty
  }

  static func latestPreservedProfileURL() throws -> URL? {
    let storage = try storageURL()
    let directory = storage.deletingLastPathComponent()
    guard isSecureDirectory(directory) else { throw ProfileStoreFailure.unsafeStorage }
    return try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ).filter { url in
      url.lastPathComponent.hasPrefix("profiles.invalid-") && isSecureRegularFile(url)
    }.sorted { left, right in
      let leftDate = try? left.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate
      let rightDate = try? right.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate
      return (leftDate ?? .distantPast) > (rightDate ?? .distantPast)
    }.first
  }

  static func saveProfileLibrary(_ library: ProfileLibrary, to url: URL) throws {
    try requireSecureDirectory(url.deletingLastPathComponent())
    if pathExistsWithoutFollowingSymlinks(url) {
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
    if pathExistsWithoutFollowingSymlinks(url) {
      _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
    } else {
      try FileManager.default.moveItem(at: temporaryURL, to: url)
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: url.path
    )
  }

  private static func decodeImportedProfileLibrary(from url: URL) throws -> ProfileLibrary {
    let data = try readRegularFileWithoutFollowingSymlinks(url, requireSecureMode: false)
    do {
      return try JSONDecoder().decode(ProfileLibrary.self, from: data)
    } catch {
      throw ProfileStoreFailure.invalidJSON(nil)
    }
  }

  private static func readRegularFileWithoutFollowingSymlinks(
    _ url: URL,
    requireSecureMode: Bool
  ) throws -> Data {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else { throw ProfileStoreFailure.unreadable }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }

    var info = stat()
    guard fstat(descriptor, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG,
      info.st_uid == getuid()
    else {
      throw ProfileStoreFailure.unreadable
    }
    if requireSecureMode, (info.st_mode & 0o077) != 0 {
      throw ProfileStoreFailure.unsafeStorage
    }
    guard info.st_size >= 0, info.st_size <= maximumFileSize else {
      throw ProfileStoreFailure.tooLarge
    }

    var data = Data()
    while data.count <= maximumFileSize {
      let remaining = maximumFileSize + 1 - data.count
      guard let chunk = try handle.read(upToCount: min(1_048_576, remaining)), !chunk.isEmpty
      else { return data }
      data.append(chunk)
    }
    throw ProfileStoreFailure.tooLarge
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

  private static func pathExistsWithoutFollowingSymlinks(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0
  }

  private static func preserveInvalid(_ data: Data, nextTo url: URL) throws -> String {
    let name = "profiles.invalid-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).json"
    let backup = url.deletingLastPathComponent().appendingPathComponent(name)
    guard
      FileManager.default.createFile(
        atPath: backup.path,
        contents: data,
        attributes: [.posixPermissions: 0o600]
      )
    else {
      throw ProfileStoreFailure.unreadable
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: backup.path
    )
    return name
  }
}

enum ProfileStoreFailure: LocalizedError {
  case unsafeStorage
  case tooLarge
  case unreadable
  case invalidJSON(String?)

  var errorDescription: String? {
    switch self {
    case .unsafeStorage:
      "Profile library has unsafe ownership, permissions, or file type."
    case .tooLarge:
      "Profile library is unexpectedly large and was not loaded."
    case .unreadable:
      "Profile library could not be read."
    case .invalidJSON(let preservedName):
      if let preservedName {
        "Profile library could not be loaded. An unchanged copy was preserved as \(preservedName)."
      } else {
        "Profile library could not be loaded."
      }
    }
  }
}
