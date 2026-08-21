import Foundation
import SBMShared

/// Privileged native profiles are authorized against the exact bundled core.
/// Updating sing-box requires reviewing this policy before native JSON is accepted.
enum NativeCapabilityPolicy {
  static let reviewedCoreVersion = "1.13.19"

  static let dialKeys: Set<String> = [
    "detour", "bind_interface", "inet4_bind_address", "inet6_bind_address",
    "bind_address_no_port", "reuse_addr", "connect_timeout", "tcp_fast_open",
    "tcp_multi_path", "disable_tcp_keep_alive", "tcp_keep_alive",
    "tcp_keep_alive_interval", "udp_fragment", "domain_resolver", "network_strategy",
    "network_type", "fallback_network_type", "fallback_delay", "domain_strategy",
  ]

  static func allowedOutboundKeys(for type: String) throws -> Set<String> {
    try requireReviewedCore()
    guard let fields = outboundFields[type] else {
      throw CoreFailure.invalidProfile(
        "Outbound type \(type) has not been authorized for the privileged helper."
      )
    }
    return fields.union(["type", "tag"])
  }

  static func allowedTransportKeys(for type: String) throws -> Set<String> {
    try requireReviewedCore()
    guard let fields = transportFields[type] else {
      throw CoreFailure.invalidProfile(
        "Transport type \(type) has not been authorized for the privileged helper."
      )
    }
    return fields.union(["type"])
  }

  static func requireAllowedDNSServerType(_ type: String) throws {
    try requireReviewedCore()
    guard allowedDNSServerTypes.contains(type) else {
      throw CoreFailure.invalidProfile(
        "DNS server type \(type.isEmpty ? "<missing>" : type) has not been authorized for the privileged helper."
      )
    }
  }

  static func requireReviewedCore(version: String = CoreBuildInfo.version) throws {
    guard version == reviewedCoreVersion else {
      throw CoreFailure.coreIntegrity(
        "Native profile policy has not been reviewed for sing-box \(version)."
      )
    }
  }

  private static let serverKeys: Set<String> = ["server", "server_port"]
  private static let tlsKey: Set<String> = ["tls"]
  private static let multiplexKey: Set<String> = ["multiplex"]
  private static let transportKey: Set<String> = ["transport"]

  private static let outboundFields: [String: Set<String>] = [
    "direct": dialKeys,
    "block": [],
    "socks": dialKeys.union(serverKeys).union([
      "version", "username", "password", "network", "udp_over_tcp",
    ]),
    "http": dialKeys.union(serverKeys).union(tlsKey).union([
      "username", "password", "path", "headers",
    ]),
    "shadowsocks": dialKeys.union(serverKeys).union(multiplexKey).union([
      "method", "password", "plugin", "plugin_opts", "network", "udp_over_tcp",
    ]),
    "vmess": dialKeys.union(serverKeys).union(tlsKey).union(multiplexKey)
      .union(transportKey).union([
        "uuid", "security", "alter_id", "global_padding", "authenticated_length",
        "network", "packet_encoding",
      ]),
    "anytls": dialKeys.union(serverKeys).union(tlsKey).union([
      "password", "idle_session_check_interval", "idle_session_timeout",
      "min_idle_session", "client_metadata",
    ]),
    "hysteria": dialKeys.union(serverKeys).union(tlsKey).union([
      "server_ports", "hop_interval", "up", "up_mbps", "down", "down_mbps",
      "obfs", "auth", "auth_str", "recv_window_conn", "recv_window",
      "disable_mtu_discovery", "network",
    ]),
    "trojan": dialKeys.union(serverKeys).union(tlsKey).union(multiplexKey)
      .union(transportKey).union(["password", "network"]),
    "ssh": dialKeys.union(serverKeys).union([
      "user", "password", "private_key", "private_key_passphrase", "host_key",
      "host_key_algorithms", "client_version",
    ]),
    "vless": dialKeys.union(serverKeys).union(tlsKey).union(multiplexKey)
      .union(transportKey).union([
        "uuid", "flow", "network", "packet_encoding",
      ]),
    "selector": ["outbounds", "default", "interrupt_exist_connections"],
    "urltest": [
      "outbounds", "url", "interval", "tolerance", "idle_timeout",
      "interrupt_exist_connections",
    ],
    "tuic": dialKeys.union(serverKeys).union(tlsKey).union([
      "uuid", "password", "congestion_control", "udp_relay_mode", "udp_over_stream",
      "zero_rtt_handshake", "heartbeat", "network",
    ]),
    "hysteria2": dialKeys.union(serverKeys).union(tlsKey).union([
      "server_ports", "hop_interval", "up_mbps", "down_mbps", "obfs", "password",
      "network", "brutal_debug",
    ]),
    "shadowtls": dialKeys.union(serverKeys).union(tlsKey).union([
      "version", "password",
    ]),
    "naive": dialKeys.union(serverKeys).union(tlsKey).union([
      "username", "password", "insecure_concurrency", "extra_headers",
      "stream_receive_window", "udp_over_tcp", "quic", "quic_congestion_control",
      "quic_session_receive_window",
    ]),
  ]

  private static let transportFields: [String: Set<String>] = [
    "http": ["host", "path", "method", "headers", "idle_timeout", "ping_timeout"],
    "ws": ["path", "headers", "max_early_data", "early_data_header_name"],
    "quic": [],
    "grpc": ["service_name", "idle_timeout", "ping_timeout", "permit_without_stream"],
    "httpupgrade": ["host", "path", "headers"],
  ]

  private static let allowedDNSServerTypes: Set<String> = [
    "local", "hosts", "udp", "tcp", "tls", "https", "h3", "quic", "fakeip",
  ]
}
