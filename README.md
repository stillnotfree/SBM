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

## Highlights

- Native Swift menu bar app with a TUN-only connection and no Electron runtime.
- Rule, Global, and Direct modes with automatic or manual server selection.
- Multiple HTTPS subscriptions and VLESS/Hysteria2 links in one selectable profile.
- Source-grouped server menus with per-source latency sorting and exclude regex filters.
- Per-subscription User-Agent, X-Device-OS, and X-HWID headers.
- Native sing-box JSON profiles for protocols not represented by compact links.
- No system-proxy mode, dashboard, traffic statistics, telemetry, or access logging.

## Install

1. Download the latest Apple Silicon DMG from
   [GitHub Releases](https://github.com/stillnotfree/SBM/releases/latest).
2. Open the DMG and drag **SBM.app** to Applications.
3. If Gatekeeper blocks it, use **System Settings > Privacy & Security > Open
   Anyway**.
4. Open **Profiles…** and add a subscription, connection link, or sing-box JSON
   profile.

SBM launches at login and reconnects the selected cached profile automatically.
See [Install and test](#install-and-test) for helper approval and testing
details.

## Profile sources

One managed profile can combine:

- multiple compact HTTPS URI subscriptions;
- multiple `vless://`, `hysteria2://`, or `hy2://` connection links.

Each HTTPS source has independent editable `User-Agent`, `X-Device-OS`, and
`X-HWID` values. Defaults are supplied for providers that require
Shadowrocket-style content negotiation, and can be replaced before syncing.
Resetting the request preset preserves the source HWID. Copying or explicitly
regenerating the HWID is available separately; it is never rotated during a
refresh or application update.
Each source also has an optional case-sensitive `Exclude regex`; use inline
flags such as `(?i)` for case-insensitive matching. Matching connection names
are removed before the menu, Auto group, and sing-box configuration are built.
The server menu keeps sources in profile order and sorts measured nodes by
latency only within their own source.
Sensitive provider headers are removed when a redirect crosses an origin.
Duplicate connection links are collapsed and a managed profile is limited to
63 proxy connections.

Separately, the app accepts:

- a native sing-box JSON profile from a local file;
- a native sing-box JSON profile from an HTTPS URL.

Native JSON is kept as a separate profile and is not merged with compact
sources.

Managed subscriptions and individual links can optionally be combined with a
separate user-owned routing JSON. The file may contain only `route.rules` and remote
`route.rule_set` entries. It is preserved when the subscription refreshes, but
can route traffic only to `direct` or to the server currently selected in the
menu. The app does not download, generate, or modify geopolitical lists on the
user's behalf.

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
read or write arbitrary local paths are rejected. The resulting candidate must
pass the bundled `sing-box check` before it can be activated. A failed runtime
activation rolls back to the previous working configuration.

In Rule mode, imported DNS servers and routing rules remain authoritative. The
imported `route.final` is replaced by the menu-controlled selector, so unmatched
traffic follows the server selected in SBM. The TUN interface routes both IPv4
and IPv6 traffic. The Direct and Global modes temporarily prepend app-owned DNS
and route overrides;
switching back to Rule restores the profile's policy without rewriting the
source profile.

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
The release pins sing-box through `Core.lock`. Maintainers update it explicitly
with `scripts/update-core.swift stable`; prerelease versions are rejected, and
the official archive, upstream binary, signed bundled binary, and embedded
helper digest are checked as separate build stages.

## Install and test

1. Open the DMG and drag `SBM.app` to Applications.
2. If Gatekeeper blocks it, use **System Settings > Privacy & Security > Open
   Anyway**.
3. Open the app and approve its background helper. With ad-hoc builds, macOS
   may require opening **System Settings > General > Login Items & Extensions**
   and allowing `SBMHelper`.
4. Open **Profiles…** and enter a private HTTPS subscription, paste an
   individual connection link, or import a JSON file.
5. For a compact subscription or connection link, optionally import a routing
   JSON in its profile editor.
6. The selected cached profile connects automatically. Use the menu-bar switch
   only when you want to disconnect it manually.

Every normal application exit, including **Disconnect & Quit** and Command-Q,
asks the helper to persist the disconnected state and stop the TUN core before
the UI terminates. When the helper is reachable, the app verifies that the core
has stopped. A broken or unavailable helper never traps the user in the app.
The launchd socket remains registered, so reopening SBM starts the helper on
demand without another installation approval.

**About SBM…** displays only the application version and copyright.
Third-party notices are bundled with the application resources as well as kept
in the source repository. The development disclosure remains in this README.

HTTPS profiles are refreshed on save, on launch, and every six hours while the
app is running. Individual connection links are local profile sources and are
not fetched from the network. A changed active profile is applied
transactionally.

Profile URLs and cached credentials are stored at
`~/Library/Application Support/SBM/profiles.json` with mode `0600`.
This avoids Keychain prompts, at the cost of weaker protection against software
already running as the same macOS user.

The app registers itself to launch when the user logs in. It checks the
`stillnotfree/SBM` GitHub Releases feed at most once per day and can also be
checked manually from the menu or About window. SBM accepts only the exact
Apple Silicon DMG for the release, enforces HTTPS redirects, size limits, and
the SHA-256 digest published by GitHub, then opens the verified image. Replacing
the app remains a user-controlled drag-and-drop action. Because builds are
ad-hoc signed, macOS may ask for background-helper approval again after an
update.

## Current status

Version 1.1.10 bundles the pinned stable sing-box 1.13.16 core and is not an
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
