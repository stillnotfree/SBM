import CoreFoundation
import Darwin
import Foundation
import SBMShared

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
    do {
      if url.lastPathComponent == fileName, profileSchemaVersion(data) == 6 {
        try requireSingleLinkRegularFile(url)
        let library = try decodeV1115ProfileLibrary(data)
        let originalURL = url.deletingLastPathComponent()
          .appendingPathComponent("profiles.1.1.15.original.json")
        try preserveOriginalProfileBytes(data, at: originalURL)
        let currentBytes = try readRegularFileWithoutFollowingSymlinks(
          url,
          requireSecureMode: true
        )
        guard currentBytes == data else { throw ProfileStoreFailure.legacySchema }
        try saveProfileLibrary(library, to: url)
        let readback = try readRegularFileWithoutFollowingSymlinks(
          url,
          requireSecureMode: true
        )
        guard try decodeProfileLibrary(readback) == library else {
          throw ProfileStoreFailure.unreadable
        }
        return library
      }
      return try decodeProfileLibrary(data)
    } catch let failure as ProfileStoreFailure {
      guard failure.isMalformedCurrentLibrary else { throw failure }
      let preservedName = preserveInvalidCopy ? try preserveInvalid(data, nextTo: url) : nil
      throw ProfileStoreFailure.invalidJSON(preservedName)
    }
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
    let library = try decodeImportedProfileLibrary(from: sourceURL)
    try saveProfileLibrary(library, to: destinationURL)
    return library
  }

  static func exportProfileLibrary(to destinationURL: URL) throws {
    try exportProfileLibrary(from: storageURL(), to: destinationURL)
  }

  static func exportProfileLibrary(from sourceURL: URL, to destinationURL: URL) throws {
    let source = sourceURL.resolvingSymlinksInPath()
    let destination = destinationURL.resolvingSymlinksInPath()
    guard source != destination else { throw CocoaError(.fileWriteUnknown) }
    let data: Data
    if pathExistsWithoutFollowingSymlinks(sourceURL) {
      guard isSecureDirectory(sourceURL.deletingLastPathComponent()) else {
        throw ProfileStoreFailure.unsafeStorage
      }
      data = try readRegularFileWithoutFollowingSymlinks(sourceURL, requireSecureMode: true)
      _ = try decodeProfileLibrary(data)
    } else {
      guard errno == ENOENT else { throw ProfileStoreFailure.unreadable }
      data = try JSONEncoder().encode(ProfileLibrary.empty)
    }
    try writeBackup(data, to: destinationURL)
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
      do {
        _ = try decodeProfileLibrary(original)
        throw ProfileStoreFailure.notMalformedCurrentSchema
      } catch let failure as ProfileStoreFailure {
        guard failure.isMalformedCurrentLibrary else { throw failure }
        _ = try preserveInvalid(original, nextTo: url)
      }
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
    let directoryURL = url.deletingLastPathComponent()
    try requireSecureDirectory(directoryURL)
    let directoryDescriptor = try openVerifiedDirectoryDescriptor(
      directoryURL,
      requireSecurePermissions: true
    )
    var directoryDescriptorOpen = true
    defer {
      if directoryDescriptorOpen { _ = close(directoryDescriptor) }
    }
    if pathExistsWithoutFollowingSymlinks(url) {
      try requireSecureRegularFile(url)
    }
    let data = try JSONEncoder().encode(library)
    guard data.count <= maximumFileSize else { throw ProfileStoreFailure.tooLarge }
    let temporaryURL = url.deletingLastPathComponent()
      .appendingPathComponent(".profiles-\(UUID().uuidString).tmp")
    let descriptor = open(
      temporaryURL.path,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK,
      0o600
    )
    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
    var descriptorOpen = true
    var renamed = false
    defer {
      if descriptorOpen { _ = close(descriptor) }
      if !renamed { _ = unlink(temporaryURL.path) }
    }

    var info = stat()
    guard fstat(descriptor, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG,
      info.st_uid == getuid()
    else { throw CocoaError(.fileWriteUnknown) }
    var offset = 0
    try data.withUnsafeBytes { bytes in
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor,
          bytes.baseAddress?.advanced(by: offset),
          bytes.count - offset
        )
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
        offset += count
      }
    }
    guard fchmod(descriptor, 0o600) == 0,
      fstat(descriptor, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG,
      info.st_nlink == 1,
      info.st_uid == getuid(),
      (info.st_mode & 0o777) == 0o600
    else { throw CocoaError(.fileWriteUnknown) }
    guard synchronizeDescriptor(descriptor) else { throw CocoaError(.fileWriteUnknown) }
    let closeResult = close(descriptor)
    descriptorOpen = false
    guard closeResult == 0 else { throw CocoaError(.fileWriteUnknown) }
    guard Darwin.rename(temporaryURL.path, url.path) == 0 else {
      throw CocoaError(.fileWriteUnknown)
    }
    renamed = true
    let directorySyncSucceeded = synchronizeDescriptor(directoryDescriptor)
    let directoryCloseResult = close(directoryDescriptor)
    directoryDescriptorOpen = false
    guard directorySyncSucceeded else { throw CocoaError(.fileWriteUnknown) }
    guard directoryCloseResult == 0 else { throw CocoaError(.fileWriteUnknown) }
  }

  private static func writeBackup(_ data: Data, to url: URL) throws {
    var existing = stat()
    if lstat(url.path, &existing) == 0 {
      guard (existing.st_mode & S_IFMT) == S_IFREG,
        existing.st_nlink == 1,
        existing.st_uid == getuid()
      else { throw CocoaError(.fileWriteUnknown) }
    } else if errno != ENOENT {
      throw CocoaError(.fileWriteUnknown)
    }

    let temporaryURL = url.deletingLastPathComponent()
      .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    let descriptor = open(
      temporaryURL.path,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK,
      0o600
    )
    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
    var descriptorOpen = true
    var renamed = false
    defer {
      if descriptorOpen { _ = close(descriptor) }
      if !renamed { _ = unlink(temporaryURL.path) }
    }

    var info = stat()
    guard fstat(descriptor, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG,
      info.st_nlink == 1
    else {
      throw CocoaError(.fileWriteUnknown)
    }
    guard fchmod(descriptor, 0o600) == 0 else { throw CocoaError(.fileWriteUnknown) }
    var offset = 0
    try data.withUnsafeBytes { bytes in
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor,
          bytes.baseAddress?.advanced(by: offset),
          bytes.count - offset
        )
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
        offset += count
      }
    }
    guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    let closeResult = close(descriptor)
    descriptorOpen = false
    guard closeResult == 0 else { throw CocoaError(.fileWriteUnknown) }
    guard Darwin.rename(temporaryURL.path, url.path) == 0 else {
      throw CocoaError(.fileWriteUnknown)
    }
    renamed = true
  }

  private static func decodeImportedProfileLibrary(from url: URL) throws -> ProfileLibrary {
    let data = try readRegularFileWithoutFollowingSymlinks(url, requireSecureMode: false)
    return try decodeProfileLibrary(data)
  }

  private static func decodeProfileLibrary(_ data: Data) throws -> ProfileLibrary {
    do {
      try StrictJSONDuplicateValidator.validate(
        data,
        maximumBytes: maximumFileSize,
        maximumDepth: 64,
        maximumStringBytes: maximumFileSize
      )
    } catch {
      throw ProfileStoreFailure.unclassifiedJSON
    }

    let currentSchemaEstablished = hasExactCurrentSchemaVersion(data)
    let library: ProfileLibrary
    do {
      library = try JSONDecoder().decode(ProfileLibrary.self, from: data)
    } catch let schemaMismatch as ProfileLibrarySchemaMismatch {
      throw ProfileStoreFailure(schemaMismatch: schemaMismatch)
    } catch {
      throw currentSchemaEstablished
        ? ProfileStoreFailure.invalidJSON(nil)
        : ProfileStoreFailure.unclassifiedJSON
    }

    guard Set(library.profiles.map(\.id)).count == library.profiles.count,
      library.profiles.allSatisfy({
        Set($0.sources.map(\.id)).count == $0.sources.count
      })
    else { throw ProfileStoreFailure.invalidJSON(nil) }
    return library
  }

  private static func decodeV1115ProfileLibrary(_ data: Data) throws -> ProfileLibrary {
    do {
      try StrictJSONDuplicateValidator.validate(
        data,
        maximumBytes: maximumFileSize,
        maximumDepth: 64,
        maximumStringBytes: maximumFileSize
      )
    } catch {
      throw ProfileStoreFailure.legacySchema
    }
    guard
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(root.keys).isSubset(of: [
        "schemaVersion", "profiles", "selectedProfileID", "localSOCKSEnabled",
        "localSOCKSPort", "latencyIntervalMinutes", "latencyTestURL", "ipv6Enabled",
      ]),
      Set(root.keys).isSuperset(of: [
        "schemaVersion", "profiles", "localSOCKSEnabled", "localSOCKSPort",
        "latencyIntervalMinutes", "latencyTestURL", "ipv6Enabled",
      ]),
      let profiles = root["profiles"] as? [[String: Any]],
      profiles.allSatisfy({ Set($0.keys).isSuperset(of: ["id", "name", "sources"]) }),
      !legacyJSONContainsKey(root, named: "autoExcludedNodeIDs")
    else { throw ProfileStoreFailure.legacySchema }

    var converted = root
    converted["schemaVersion"] = ProfileLibrary.currentSchemaVersion
    if converted["selectedProfileID"] == nil { converted["selectedProfileID"] = NSNull() }
    converted["routingMode"] = RoutingMode.rule.rawValue
    converted["selectedNodeID"] = ProxyNodeID.auto.rawValue
    converted["dnsSettings"] = try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(ManagedDNSSettings.defaults)
    )
    let projected: Data
    do {
      projected = try JSONSerialization.data(
        withJSONObject: converted,
        options: [.sortedKeys, .fragmentsAllowed]
      )
      let library = try decodeProfileLibrary(projected)
      guard
        legacyRoundTripMatches(root, library: library),
        library.selectedProfileID == nil
          || library.profiles.contains(where: { $0.id == library.selectedProfileID }),
        library.profiles.allSatisfy({ profile in
          profile.sources.allSatisfy {
            $0.headers.deviceOSVersion == nil && $0.headers.deviceModel == nil
              && legacySourceIsAdmissible($0)
          }
        }),
        library.profiles.allSatisfy({ profile in
          legacyPayloads(in: profile).allSatisfy(legacyPayloadHasValidReferences)
        })
      else { throw ProfileStoreFailure.legacySchema }
      return library
    } catch let failure as ProfileStoreFailure {
      if case .legacySchema = failure { throw failure }
      throw ProfileStoreFailure.legacySchema
    } catch {
      throw ProfileStoreFailure.legacySchema
    }
  }

  private static func legacyRoundTripMatches(_ original: [String: Any], library: ProfileLibrary)
    -> Bool
  {
    guard
      let encoded = try? JSONEncoder().encode(library),
      var roundTrip = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    else { return false }
    roundTrip["schemaVersion"] = 6
    roundTrip.removeValue(forKey: "routingMode")
    roundTrip.removeValue(forKey: "selectedNodeID")
    roundTrip.removeValue(forKey: "dnsSettings")
    if roundTrip["selectedProfileID"] is NSNull {
      roundTrip.removeValue(forKey: "selectedProfileID")
    }
    removeAddedProfileFields(from: &roundTrip)
    guard
      let originalData = try? JSONSerialization.data(
        withJSONObject: original, options: [.sortedKeys]),
      let roundTripData = try? JSONSerialization.data(
        withJSONObject: roundTrip, options: [.sortedKeys])
    else { return false }
    return originalData == roundTripData
  }

  private static func removeAddedProfileFields(from value: inout [String: Any]) {
    value.removeValue(forKey: "autoExcludedNodeIDs")
    for key in Array(value.keys) {
      if var object = value[key] as? [String: Any] {
        removeAddedProfileFields(from: &object)
        value[key] = object
      } else if var array = value[key] as? [[String: Any]] {
        for index in array.indices { removeAddedProfileFields(from: &array[index]) }
        value[key] = array
      }
    }
  }

  private static func legacyJSONContainsKey(_ value: Any, named key: String) -> Bool {
    if let object = value as? [String: Any] {
      return object[key] != nil || object.values.contains { legacyJSONContainsKey($0, named: key) }
    }
    if let array = value as? [Any] {
      return array.contains { legacyJSONContainsKey($0, named: key) }
    }
    return false
  }

  private static func legacyPayloads(in profile: ManagedProfile) -> [CoreProfile] {
    [profile.payload].compactMap { $0 }
      + profile.sources.compactMap(\.payload)
  }

  private static func legacyPayloadHasValidReferences(_ payload: CoreProfile) -> Bool {
    guard case .compatibility(let profile) = payload else { return false }
    let nodeIDs = profile.connections.map(\.id)
    guard Set(nodeIDs).count == nodeIDs.count,
      !nodeIDs.contains(.auto),
      profile.connections.allSatisfy({ legacyOutboundHasV1115Shape($0.outbound) }),
      Set(profile.applicationRoutingRules.map(\.id)).count == profile.applicationRoutingRules.count,
      Set(profile.websiteRoutingRules.map(\.id)).count == profile.websiteRoutingRules.count,
      Set((profile.nodeGroups ?? []).map(\.id)).count == (profile.nodeGroups ?? []).count,
      (profile.nodeGroups ?? []).allSatisfy({ group in
        Set(group.nodes).count == group.nodes.count && group.nodes.allSatisfy(nodeIDs.contains)
      })
    else { return false }
    guard
      profile.applicationRoutingRules.allSatisfy({ rule in
        if case .node(let nodeID) = rule.target { return nodeIDs.contains(nodeID) }
        return true
      })
    else { return false }
    return profile.routingPolicy.map { policy in
      (try? RoutingPolicyParser.parse(policy.configuration)) == policy
    } ?? true
  }

  private static func legacySourceIsAdmissible(_ source: ManagedSource) -> Bool {
    do {
      try SubscriptionClient.validate(headers: source.headers)
      if !source.value.isEmpty,
        try SubscriptionClient.validateSourceValue(source.value) != source.value
      {
        return false
      }
      if let filter = source.excludeRegex,
        !filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        try SourceNameFilter.normalized(filter) != filter
      {
        return false
      }
      return true
    } catch {
      return false
    }
  }

  private static func legacyOutboundHasV1115Shape(_ outbound: ManagedOutbound) -> Bool {
    switch outbound {
    case .vless(let profile):
      switch profile.variant {
      case .reality, .tlsGRPC: return true
      default: return false
      }
    case .hysteria2(let profile):
      return profile.portHoppingRanges == nil
    case .shadowsocks:
      return true
    }
  }

  private static func profileSchemaVersion(_ data: Data) -> Int? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let number = root["schemaVersion"] as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(),
      !CFNumberIsFloatType(number as CFNumber)
    else { return nil }
    return number.intValue
  }

  private static func preserveOriginalProfileBytes(_ data: Data, at url: URL) throws {
    let directoryURL = url.deletingLastPathComponent()
    let directoryDescriptor = try openVerifiedDirectoryDescriptor(
      directoryURL,
      requireSecurePermissions: true
    )
    var directoryDescriptorOpen = true
    defer {
      if directoryDescriptorOpen { _ = close(directoryDescriptor) }
    }

    if let existing = try readSecureOriginalProfileBytes(
      named: url.lastPathComponent,
      in: directoryDescriptor
    ) {
      guard existing == data else { throw ProfileStoreFailure.legacySchema }
      guard synchronizeDescriptor(directoryDescriptor) else {
        throw ProfileStoreFailure.unreadable
      }
      let closeResult = close(directoryDescriptor)
      directoryDescriptorOpen = false
      guard closeResult == 0 else { throw ProfileStoreFailure.unreadable }
      return
    }

    let temporaryName = ".profiles-preserve-\(UUID().uuidString).tmp"
    let descriptor = openat(
      directoryDescriptor,
      temporaryName,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK,
      0o600
    )
    guard descriptor >= 0 else { throw ProfileStoreFailure.unreadable }
    var descriptorOpen = true
    var temporaryNameRemoved = false
    defer {
      if descriptorOpen { _ = close(descriptor) }
      if !temporaryNameRemoved { _ = unlinkat(directoryDescriptor, temporaryName, 0) }
    }
    var info = stat()
    guard fstat(descriptor, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG,
      info.st_uid == getuid(),
      info.st_nlink == 1
    else { throw ProfileStoreFailure.unsafeStorage }
    var offset = 0
    try data.withUnsafeBytes { bytes in
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor,
          bytes.baseAddress?.advanced(by: offset),
          bytes.count - offset
        )
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw ProfileStoreFailure.unreadable }
        offset += count
      }
    }
    guard fchmod(descriptor, 0o600) == 0,
      synchronizeDescriptor(descriptor)
    else { throw ProfileStoreFailure.unreadable }
    let closeResult = close(descriptor)
    descriptorOpen = false
    guard closeResult == 0 else { throw ProfileStoreFailure.unreadable }
    if renameatx_np(
      directoryDescriptor,
      temporaryName,
      directoryDescriptor,
      url.lastPathComponent,
      UInt32(RENAME_EXCL)
    ) == 0 {
      temporaryNameRemoved = true
    } else if errno == EEXIST {
      guard unlinkat(directoryDescriptor, temporaryName, 0) == 0 else {
        throw ProfileStoreFailure.unreadable
      }
      temporaryNameRemoved = true
      guard
        try readSecureOriginalProfileBytes(
          named: url.lastPathComponent,
          in: directoryDescriptor
        ) == data
      else {
        throw ProfileStoreFailure.legacySchema
      }
    } else {
      throw ProfileStoreFailure.unreadable
    }
    guard synchronizeDescriptor(directoryDescriptor),
      try readSecureOriginalProfileBytes(
        named: url.lastPathComponent,
        in: directoryDescriptor
      ) == data
    else { throw ProfileStoreFailure.unreadable }
    let directoryCloseResult = close(directoryDescriptor)
    directoryDescriptorOpen = false
    guard directoryCloseResult == 0 else { throw ProfileStoreFailure.unreadable }
  }

  private static func readSecureOriginalProfileBytes(
    named name: String,
    in directoryDescriptor: Int32
  ) throws -> Data? {
    let descriptor = openat(directoryDescriptor, name, O_RDWR | O_NONBLOCK | O_NOFOLLOW)
    if descriptor < 0, errno == ENOENT { return nil }
    guard descriptor >= 0 else { throw ProfileStoreFailure.unsafeStorage }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    var descriptorOpen = true
    defer {
      if descriptorOpen { _ = close(descriptor) }
    }
    var info = stat()
    guard fstat(descriptor, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG,
      info.st_uid == getuid(),
      info.st_nlink == 1,
      (info.st_mode & 0o777) == 0o600,
      info.st_size >= 0,
      info.st_size <= maximumFileSize
    else { throw ProfileStoreFailure.unsafeStorage }
    guard let data = try handle.readToEnd(), data.count == info.st_size else {
      throw ProfileStoreFailure.unreadable
    }
    guard synchronizeDescriptor(descriptor) else { throw ProfileStoreFailure.unreadable }
    let closeResult = close(descriptor)
    descriptorOpen = false
    guard closeResult == 0 else { throw ProfileStoreFailure.unreadable }
    return data
  }

  private static func hasExactCurrentSchemaVersion(_ data: Data) -> Bool {
    guard
      let root = try? JSONSerialization.jsonObject(
        with: data,
        options: [.fragmentsAllowed]
      ) as? [String: Any],
      let version = root["schemaVersion"] as? NSNumber,
      CFGetTypeID(version) != CFBooleanGetTypeID(),
      !CFNumberIsFloatType(version as CFNumber)
    else { return false }
    return version.intValue == ProfileLibrary.currentSchemaVersion
  }

  private static func readRegularFileWithoutFollowingSymlinks(
    _ url: URL,
    requireSecureMode: Bool
  ) throws -> Data {
    let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
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
      var existingDirectoryInfo = stat()
      if lstat(directory.path, &existingDirectoryInfo) != 0, errno != ENOENT {
        throw CocoaError(.fileWriteNoPermission)
      }
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
      let parentDescriptor = try openVerifiedDirectoryDescriptor(
        directory.deletingLastPathComponent(),
        requireSecurePermissions: false
      )
      var parentDescriptorOpen = true
      defer {
        if parentDescriptorOpen { _ = close(parentDescriptor) }
      }
      let parentSyncSucceeded = synchronizeDescriptor(parentDescriptor)
      let parentCloseResult = close(parentDescriptor)
      parentDescriptorOpen = false
      guard parentSyncSucceeded else { throw CocoaError(.fileWriteUnknown) }
      guard parentCloseResult == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    return directory.appendingPathComponent(fileName)
  }

  private static func openVerifiedDirectoryDescriptor(
    _ url: URL,
    requireSecurePermissions: Bool
  ) throws -> Int32 {
    guard url.resolvingSymlinksInPath() == url.standardizedFileURL else {
      throw CocoaError(.fileWriteNoPermission)
    }
    let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }

    var descriptorInfo = stat()
    var pathInfo = stat()
    guard fstat(descriptor, &descriptorInfo) == 0,
      lstat(url.path, &pathInfo) == 0,
      (descriptorInfo.st_mode & S_IFMT) == S_IFDIR,
      descriptorInfo.st_uid == getuid(),
      descriptorInfo.st_dev == pathInfo.st_dev,
      descriptorInfo.st_ino == pathInfo.st_ino,
      !requireSecurePermissions || (descriptorInfo.st_mode & 0o077) == 0
    else {
      _ = close(descriptor)
      throw CocoaError(.fileWriteNoPermission)
    }
    return descriptor
  }

  private static func synchronizeDescriptor(_ descriptor: Int32) -> Bool {
    while fsync(descriptor) != 0 {
      if errno == EINTR { continue }
      return false
    }
    return true
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
    guard url.resolvingSymlinksInPath() == url.standardizedFileURL else { return false }
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

  private static func requireSingleLinkRegularFile(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
    guard descriptor >= 0 else { throw ProfileStoreFailure.unsafeStorage }
    var info = stat()
    let valid =
      fstat(descriptor, &info) == 0
      && (info.st_mode & S_IFMT) == S_IFREG
      && info.st_uid == getuid()
      && info.st_nlink == 1
      && (info.st_mode & 0o077) == 0
    let closeResult = close(descriptor)
    guard valid, closeResult == 0 else { throw ProfileStoreFailure.unsafeStorage }
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
  case legacySchema
  case unsupportedFutureSchema(Int)
  case invalidJSON(String?)
  case unclassifiedJSON
  case notMalformedCurrentSchema

  init(schemaMismatch: ProfileLibrarySchemaMismatch) {
    switch schemaMismatch {
    case .legacy:
      self = .legacySchema
    case .unsupportedFuture(let version):
      self = .unsupportedFutureSchema(version)
    }
  }

  var isMalformedCurrentLibrary: Bool {
    if case .invalidJSON = self { true } else { false }
  }

  var errorDescription: String? {
    switch self {
    case .unsafeStorage:
      SBMText.localized("Profile library has unsafe ownership, permissions, or file type.")
    case .tooLarge:
      SBMText.localized("Profile library is unexpectedly large and was not loaded.")
    case .unreadable:
      SBMText.localized("Profile library could not be read.")
    case .legacySchema:
      SBMText.localized(
        "SBM could not safely convert this legacy profile library. Keep ~/Library/Application Support/SBM/profiles.json in place and contact support; the original file was left unchanged."
      )
    case .unsupportedFutureSchema(let version):
      SBMText.format(
        "This profile library uses newer unsupported schema %@. The file at ~/Library/Application Support/SBM/profiles.json was left unchanged. Open it with a newer SBM version.",
        String(version)
      )
    case .invalidJSON(let preservedName):
      if let preservedName {
        SBMText.format(
          "Profile library could not be loaded. An unchanged copy was preserved as %@.",
          preservedName
        )
      } else {
        SBMText.localized("Profile library could not be loaded.")
      }
    case .unclassifiedJSON:
      SBMText.localized("Profile library could not be loaded.")
    case .notMalformedCurrentSchema:
      SBMText.localized("The profile library is valid and cannot be recovered as corrupt data.")
    }
  }
}
