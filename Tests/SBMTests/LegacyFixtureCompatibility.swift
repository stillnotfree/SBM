import SBMShared

// These fixture-only adapters keep older test data readable while the shipped
// model remains connections-only. They are not part of the app or helper
// targets and do not participate in profile decoding.
extension VLESSProfile {
  init(
    server: String,
    port: UInt16,
    uuid: String,
    serverName: String,
    fingerprint: String,
    publicKey: String,
    shortID: String,
    displayName: String
  ) {
    self.init(
      server: server,
      port: port,
      uuid: uuid,
      serverName: serverName,
      fingerprint: fingerprint,
      publicKey: publicKey,
      shortID: shortID
    )
  }
}

extension Hysteria2Profile {
  init(
    server: String,
    port: UInt16,
    password: String,
    serverName: String,
    obfsPassword: String? = nil,
    displayName: String
  ) {
    self.init(
      server: server,
      port: port,
      password: password,
      serverName: serverName,
      obfsPassword: obfsPassword
    )
  }
}

extension ShadowsocksProfile {
  init(
    server: String,
    port: UInt16,
    method: String,
    password: String,
    displayName: String
  ) {
    self.init(server: server, port: port, method: method, password: password)
  }
}

extension ManagedConnection {
  init(id: ProxyNodeID? = nil, outbound: ManagedOutbound) {
    let name: String
    switch outbound.kind {
    case .vless: name = "VLESS"
    case .hysteria2: name = "Hysteria2"
    case .shadowsocks: name = "Shadowsocks"
    default: name = "Connection"
    }
    self.init(id: id, displayName: name, outbound: outbound)
  }
}

extension VPNProfile {
  init(
    vless: [VLESSProfile] = [],
    hysteria2: [Hysteria2Profile] = [],
    shadowsocks: [ShadowsocksProfile] = [],
    routingPolicy: RoutingPolicy? = nil,
    nodeGroups: [ProxyNodeGroup] = [],
    applicationRoutingRules: [ApplicationRoutingRule] = [],
    websiteRoutingRules: [WebsiteRoutingRule] = []
  ) {
    let connections =
      vless.enumerated().map { entry in
        ManagedConnection(
          id: ProxyNodeID(rawValue: "vless-\(entry.offset + 1)"),
          displayName: "VLESS",
          outbound: .vless(entry.element)
        )
      }
      + hysteria2.enumerated().map { entry in
        ManagedConnection(
          id: ProxyNodeID(rawValue: "hysteria2-\(entry.offset + 1)"),
          displayName: "Hysteria2",
          outbound: .hysteria2(entry.element)
        )
      }
      + shadowsocks.enumerated().map { entry in
        ManagedConnection(
          id: ProxyNodeID(rawValue: "shadowsocks-\(entry.offset + 1)"),
          displayName: "Shadowsocks",
          outbound: .shadowsocks(entry.element)
        )
      }
    self.init(
      connections: connections,
      routingPolicy: routingPolicy,
      nodeGroups: nodeGroups,
      applicationRoutingRules: applicationRoutingRules,
      websiteRoutingRules: websiteRoutingRules
    )
  }

  var vless: [VLESSProfile] {
    connections.compactMap { if case .vless(let value) = $0.outbound { value } else { nil } }
  }

  var hysteria2: [Hysteria2Profile] {
    connections.compactMap { if case .hysteria2(let value) = $0.outbound { value } else { nil } }
  }

  var shadowsocks: [ShadowsocksProfile] {
    connections.compactMap { if case .shadowsocks(let value) = $0.outbound { value } else { nil } }
  }
}
