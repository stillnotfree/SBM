<p align="center">
  <img src="Resources/AppIcon.icon/Assets/sing-box.png" width="144" alt="SBM icon">
</p>

<h1 align="center">SBM</h1>

<p align="center">
  A minimal native sing-box client for macOS, built exclusively for Apple Silicon.
</p>

<p align="center">
  <a href="https://github.com/stillnotfree/SBM/releases/latest"><img src="https://img.shields.io/github/v/release/stillnotfree/SBM?sort=semver" alt="Latest release"></a>
  <a href="https://github.com/stillnotfree/SBM/releases"><img src="https://img.shields.io/github/downloads/stillnotfree/SBM/total" alt="Downloads"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-black?logo=apple" alt="macOS 26 or newer">
  <img src="https://img.shields.io/badge/Apple%20Silicon-native-black" alt="Apple Silicon native">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/stillnotfree/SBM" alt="MIT license"></a>
</p>

<p align="center">
  English · <a href="README_RU.md">Русский</a>
</p>

> **Development disclosure:** this project was vibe-coded and generated
> primarily by an AI coding agent (OpenAI Codex), under human direction,
> review, and testing. It has not received an independent professional security
> audit.

Unless a feature is explicitly stated in release notes, this README describes
the current source tree and does not assert its availability in the v1.1.14
release.

## Highlights

- Native Swift menu bar app with a TUN-only connection and no Electron runtime.
- Rule, Global, and Direct modes with automatic or manual server selection.
- Multiple HTTPS subscriptions and VLESS/Hysteria2/Shadowsocks links in one selectable profile.
- Source-grouped server menus that preserve subscription order, with latency badges and exclude regex filters.
- Per-subscription User-Agent, X-App-Version, X-Device-OS, and X-HWID headers.
- Exact per-application DIRECT, current-proxy, stable-server, or REJECT routing.
- Per-profile website routing to Proxy, Direct, or Reject without editing JSON.
- A local, probe-free Routing Inspector for deterministic composed rules.
- Native sing-box JSON profiles for protocols not represented by compact links.
- Always-available diagnostics with 50 bounded, deduplicated, redacted recent errors.
- No system-proxy mode, dashboard, traffic statistics, telemetry, or access logging.
- IPv4 user-traffic policy: IPv6 stays captured by the managed TUN and is rejected locally before traffic sniffing.

## Install

1. Download the latest Apple Silicon DMG from
   [GitHub Releases](https://github.com/stillnotfree/SBM/releases/latest).
2. Open the DMG and drag **SBM.app** to Applications.
3. If Gatekeeper blocks it, use **System Settings > Privacy & Security > Open
   Anyway**.
4. Open **Settings…** and add a subscription, connection link, or sing-box JSON
   profile.

SBM launches at login and reconnects the selected cached profile automatically.
See [Install and test](#install-and-test) for helper approval and testing
details.

## Profile sources

One managed profile can combine:

- multiple compact HTTPS URI subscriptions;
- multiple `vless://`, `hysteria2://`, `hy2://`, or `ss://` connection links.

Each HTTPS source has independent editable `User-Agent`, `X-App-Version`,
`X-Device-OS`, and `X-HWID` values. New sources reproduce the stable
client-identification fields from a user-captured Happ 5.4.0 iOS request. SBM
does not invent the captured device model, OS version, locale, or transport
headers, and every field can be replaced before syncing.
Resetting the request preset preserves the source HWID. Copying or explicitly
regenerating the HWID is available separately; generated values use canonical UUID strings. SBM does not claim to reproduce
Happ's internal generation algorithm. The HWID is never rotated during a refresh or
application update.
Each source also has an optional case-sensitive `Exclude regex`; use inline
flags such as `(?i)` for case-insensitive matching. Matching connection names
are removed before the menu, Auto group, and sing-box configuration are built.
The server menu keeps sources and nodes in subscription/profile order; latency is
displayed as metadata and does not reorder manual-selection entries.
Sensitive provider headers are removed when a redirect crosses an origin.
Duplicate connection links are collapsed and a managed profile is limited to
63 proxy connections.

Managed connections use typed stable IDs. A profile library in the v1.1.11
layout (schema 1) is migrated automatically through a one-way DTO boundary;
the immediately previous schema 4 is also rewritten to current schema 5 and
saved atomically before use. On a subscription refresh, a node renamed or reordered without a
change to its connection identity keeps its ID; the active managed profile is
not reactivated for that change alone. A changed outbound or routing policy is
validated and saved as desired state while a known-good running runtime remains
active; **Reconnect to Apply** performs the required explicit stop and start.

Shadowsocks compact links are limited to plugin-free, strict SIP002 `ss://`
URIs. The exact supported methods are `aes-128-gcm`, `aes-256-gcm`,
`chacha20-ietf-poly1305`, `2022-blake3-aes-128-gcm`,
`2022-blake3-aes-256-gcm`, and `2022-blake3-chacha20-poly1305`. Plugins, every
query parameter, and the legacy whole-URI Base64 form are rejected. This
compact-link support does not expand support for arbitrary Shadowsocks or other
protocol configurations; use a separate native sing-box JSON profile where the
bundled core and SBM's import policy support the required configuration.

Separately, the app accepts:

- a native sing-box JSON profile from a local file;
- a native sing-box JSON profile from an HTTPS URL.

Native JSON is kept as a separate profile and is not merged with compact
sources.

## Latency target and privacy

In **Settings… > Advanced**, set the **Test target** HTTPS URL and choose **Apply** to
save it. SBM validates an absolute HTTPS URL without credentials or fragments.
While the VPN is connected, a latency test sends an HTTPS request to that target
through each tested proxy; choose an endpoint you trust. Its operator can
observe the request time and the proxy egress address, as with any HTTPS
request to that endpoint. The target used for latency measurement is separate
from sing-box's URLTest interval used by Auto selection. Manual tests use a
newly applied target immediately; SBM-created Auto groups receive it on the next
normal connection. Imported native URLTest outbounds remain unchanged.

The always-available Diagnostics window copies a bounded support snapshot as
text or sorted-key JSON and retains at most 50 sanitized recent failures with
consecutive deduplication and a Clear History action. It aggregates already
observed state and runs no DNS, network, latency, or process probe. Profile and
node names/IDs, subscription data, headers, credentials, raw native JSON, and
logs are omitted. Errors are sanitized both when retained and when exported;
large histories are deterministically truncated without discarding current
status.

The menu **Refresh** action refreshes observed helper status and forces every
eligible remote subscription source to synchronize once without restarting the
VPN. Independent source failures do not stop the sweep; duplicate manual sweeps
are coalesced, and a materially changed active profile is validated and saved
through the normal runtime coordinator while a known-good running runtime stays
active. **Reconnect to Apply** explicitly stops and starts the latest deferred
candidate.
Local compact links are not fetched. A source deleted or edited before its turn
is not requested with stale URL or headers. If activation fails, valid refreshed
data remains saved for retry and newer routing edits are preserved; the UI
distinguishes that saved state from the previous known-good active runtime. The pinned sing-box
1.13.19 interface provides scheduled remote
rule-set updates through `update_interval`, but no supported bounded control
operation to force-refresh the running rule sets, so **Refresh** does not claim
to do that.

Managed subscriptions and individual links can optionally be combined with a
separate user-owned routing JSON. The file may contain only `route.rules` and remote
`route.rule_set` entries. It is preserved when the subscription refreshes, but
can route traffic only to `direct` or to the server currently selected in the
menu. The app does not download, generate, or modify geopolitical lists on the
user's behalf.

Website rules are profile-specific, limited to 128 normalized hostnames, match
both the exact apex and its subdomains, and target Proxy, Direct, or Reject.
Their precedence is: mandatory SBM safety, Website Routing, Application
Routing, imported routing, then the final route. A Direct website rule receives
the matching local-DNS policy; Proxy retains remote/proxied DNS and Reject does
not create a physical bypass. Website rules work for compatibility and native
profiles without broadening native import capabilities.

Application rules use the exact main executable from a selected macOS `.app`.
They run after website rules and before imported routing, and can
target DIRECT, the current proxy selector, one stable managed server, or native
REJECT. A moved or deleted application remains visible but inactive; SBM does not guess by
name or scan bundles for other executables. Application rules do not create a
separate DNS policy.

Routing Inspector explains deterministic domain or IP decisions from the final
composed route without DNS, network, process, or persistence probes.
`Default traffic` means traffic that does not match a configured application
override; selecting an application evaluates its exact stored executable path.
The primary result is PROXY, DIRECT, or REJECT. For remote rule-sets, the helper
reads the exact active sing-box cache and asks the pinned core's bounded
`rule-set match` command; no list is downloaded by Explain and only match
booleans cross IPC. If the selected profile is not active, its cache is absent,
or another rule still needs a resolved IP, port, sniffed protocol, or unrelated
process context, the inspector names that specific limitation.

[`Examples/routing-ru-direct.json`](Examples/routing-ru-direct.json) is a
minimal optional example: Russian domains and IP ranges go direct,
`google.ru` stays proxied, and everything else follows the selected VPN
server. Its three official SagerNet rule-sets are fetched by sing-box through
the selected proxy and refreshed daily. Rule-mode DNS follows the same direct
domain rules, so Russian destinations are not resolved through the proxy.

Native profiles provide their own outbounds, DNS, routing rules, and remote
rule-sets. The menu discovers selector members dynamically. When a profile has
no selector or URLTest group, the app creates a local selector and `Auto` group.
No geopolitical rule database is bundled or silently injected.

The privileged helper always owns the TUN inbound, optional loopback-only SOCKS5
listener, warning log, cache, and loopback-only Clash API. Imported local
listeners, services, filesystem paths, system-managed endpoints, and exposed control APIs are rejected or replaced.
Safe userspace outbounds and endpoints supported by the bundled core are kept.
Imported DNS, route, outbound, endpoint, TLS, and transport sections must use
the explicit safe fields supported by this SBM build. Capabilities that can
launch another process, create a listener, select a system-managed endpoint, or
read or write arbitrary local paths are rejected. The resulting complete
candidate, including its runtime API secret, must pass the bundled `sing-box
check` before the working core is stopped. A failed runtime activation restores
the previous working configuration and core.

In Rule mode, imported DNS servers and routing rules remain authoritative below
SBM's mandatory and first-class routing layers. The
imported `route.final` is replaced by the menu-controlled selector, so unmatched
traffic follows the server selected in SBM. The generated TUN retains IPv4 and
IPv6 addresses with `auto_route` and `strict_route`, but SBM currently routes
user traffic over IPv4: IPv6 is captured by the managed TUN and rejected locally
before the unconditional traffic sniff. This avoids physical IPv6 bypass and
unreliable Direct behavior; it is not complete IPv6 support. Hostname DNS
remains intentionally `ipv4_only`, and IPv4 Direct/Proxy/Global semantics are
unchanged. The Direct and Global modes temporarily prepend app-owned DNS and
route overrides; switching back to Rule restores the profile's policy without
rewriting the source profile.

The root helper accepts commands only from local administrator accounts. It
validates and constrains imported profiles before starting the bundled root-owned
sing-box core; installing SBM therefore extends the trusted local boundary to
all macOS administrator accounts.

Optional menu metadata can be added to a native profile:

```json
{
  "sbm": {
    "selector": "proxy",
    "display_names": {
      "de-reality": "🇩🇪 Reality",
      "de-hysteria2": "🇩🇪 Hysteria2"
    }
  }
}
```

The `sbm` object is consumed by the app and is not passed to sing-box.

## Requirements

- Apple Silicon Mac
- macOS 26 or newer
- administrator access for the background helper

## Build

```sh
make dmg
```

The distributable image is written to `dist/`.
Before packaging a proposed release, run the local, non-publishing gate with the
version already set in the repository metadata, for example:

```sh
make release-check TAG=v1.1.14
```

It checks release metadata and local verification commands, then builds and
validates `dist/SBM.app`. It does not create a tag or release, commit, push,
install, or open SBM.

The release pins sing-box through `Core.lock`. Maintainers update it explicitly
with `scripts/update-core.swift stable`; prerelease versions are rejected, and
the official archive, upstream binary, signed bundled binary, and embedded
helper digest are checked as separate build stages.

For a reproducible local CPU, memory, and wakeup baseline, follow the
[performance baseline protocol](docs/PERFORMANCE.md). Its read-only sampler
uses caller-supplied process IDs and JSON Lines output; results describe only
the stated machine, build, profile, network, and procedure, not a general SBM
performance or power claim.

## Install and test

1. Open the DMG and drag `SBM.app` to Applications.
2. If Gatekeeper blocks it, use **System Settings > Privacy & Security > Open
   Anyway**.
3. Open the app and approve its background helper. With ad-hoc builds, macOS
   may require opening **System Settings > General > Login Items & Extensions**
   and allowing `SBMHelper`. SBM waits for the system-reported approval state
   and then verifies or replaces the helper automatically; returning to SBM
   does not require a separate Refresh or Repair action.
4. Open **Settings…** and enter a private HTTPS subscription, paste an
   individual connection link, or import a JSON file.
5. For a compact subscription or connection link, optionally import a routing
   JSON in its profile editor.
6. The selected cached profile connects automatically. Use the menu-bar switch
   only when you want to disconnect it manually.

Every normal application exit, including **Disconnect & Quit** and Command-Q,
asks the helper to persist the disconnected state and stop the TUN core before
the UI terminates. When the helper is reachable, the app verifies that the core
has stopped. If shutdown fails or the stopped state cannot be proven, SBM denies
termination and remains open so Disconnect & Quit can be retried.
Failure to contact the helper is displayed as an unknown VPN state, never as a
proven disconnection. An explicit Disconnect remains authoritative across later
settings edits and suppresses same-session automatic reconnection.
The launchd socket remains registered, so reopening SBM starts the helper on
demand without another installation approval.

**About SBM…** displays only the application version and copyright.
Third-party notices are bundled with the application resources as well as kept
in the source repository. The development disclosure remains in this README.

HTTPS profiles are refreshed on save, on launch, and every six hours while the
app is running. Individual connection links are local profile sources and are
not fetched from the network. A changed active profile is validated without
replacing a running known-good runtime; the helper persists the reconnect-needed
state while that runtime remains active. **Reconnect to Apply** applies the
latest candidate through the explicit stop/start transaction.

Profile URLs and cached credentials are stored at
`~/Library/Application Support/SBM/profiles.json` with mode `0600`.
This avoids Keychain prompts, at the cost of weaker protection against software
already running as the same macOS user.

If that library is malformed, SBM keeps the original and a preserved copy,
blocks ordinary saves, and presents explicit recovery actions in Profiles:
import a corrected library, reveal the preserved copy, or preserve it again and
start empty after disconnecting the VPN.

The app registers itself to launch when the user logs in. It checks the
`stillnotfree/SBM` GitHub Releases feed at most once per day and can also be
checked manually from the menu or About window. SBM accepts only the exact
Apple Silicon DMG for the release, enforces HTTPS redirects, size limits, and
the SHA-256 digest published by GitHub, then opens the verified image. Replacing
the app remains a user-controlled drag-and-drop action. Because builds are
ad-hoc signed, macOS may ask for background-helper approval again after an
update.

## Current status

Version 1.1.14 bundles the pinned stable sing-box 1.13.19 core and is not an
independently audited security product.
Multi-source compatibility profiles and individual connection links using VLESS +
REALITY + Vision or Hysteria2 + TLS with either no obfuscation or Salamander are
covered by the test suite, including custom request headers, redirects,
deduplication, single-protocol profiles, and profiles with both protocols.
Generic native JSON profiles are validated automatically against the bundled
core; a userspace WireGuard endpoint is covered by the test suite. This does
not claim that every sing-box protocol has been tested against every provider.

Please report suspected vulnerabilities through the
[private security policy](SECURITY.md), not a public issue.
