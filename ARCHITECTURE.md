# Architecture baseline

## Scope

- Apple Silicon only.
- Current stable macOS only (deployment target 26.0).
- Native SwiftUI menu bar application.
- TUN only; no system proxy.
- sing-box is the only packet-processing core.
- No traffic statistics, dashboard, access log, telemetry, or web UI.
- Profiles own DNS, routing, remote rule-sets, and proxy outbounds.
- The application owns the TUN inbound, local API, cache, and warning log.
- The managed TUN uses an MTU of 1400. The app does not globally reject QUIC;
  transport policy remains with the selected profile and the network.

## Process boundary

The unprivileged UI never launches shell commands and never runs sing-box as
the logged-in user. A bundled launch daemon owns the TUN process and the files
that affect routing or DNS.

```text
SwiftUI menu bar app (user)
        |
        | versioned, bounded local request
        v
launchd helper (root)
        |
        | validated config + fixed executable path
        v
sing-box (root, TUN)
```

The client uses a root-owned Unix socket. Requests are length-bounded JSON
messages with an enum action; there is no command string, path, environment, or
arbitrary argument field. The helper authenticates the peer UID and accepts
requests only from root or members of the local `admin` group. Both sides apply
send/receive timeouts, bounded framing, `SO_NOSIGPIPE`, partial-write handling,
and `EINTR` recovery.

The helper verifies the exact ad-hoc-signed bundled core by SHA-256, copies it
atomically to a root-owned executable with mode `0500`, and never executes the
copy inside the user-writable application bundle. It validates a candidate
configuration with that protected core before atomically replacing the active
configuration. Runtime state, client secrets, the local API token, the protected
core, and warning logs are root-only under
`/Library/Application Support/SBM`.

`Core.lock` pins the stable upstream version, archive digest, and unsigned
binary digest. Packaging verifies those inputs, ad-hoc signs one exact core,
generates `CoreBuildInfo.swift` from its signed digest, compiles the helper, and
bundles that same file without signing it again. Critical root files are staged
in the protected directory, synchronized, and replaced with same-directory
`rename`; verified configuration and core backups are retained for rollback.
Before replacing an installed core, the helper checks the known-good active
configuration with the verified candidate and keeps the old process running
until the replacement and metadata are committed. The previous core is backed
up only when its protected metadata, content digest, and reported version agree;
a post-replacement file or metadata failure atomically restores that backup.

Disconnect is persisted before the process is terminated. On every helper
bootstrap, a disconnected state also removes a verified leftover core process
referenced by the root-owned PID file. This makes `Disconnect & Quit` durable
across helper crashes and launchd restarts. The helper receives its root-owned
Unix listener from launchd socket activation and exits after an application
shutdown request; launchd starts it again on the next local request.

An explicitly connected state arms one automatic recovery. If the protected
core disappears unexpectedly, the next helper activation rechecks the
known-good configuration and restarts it once. The attempt is persisted before
launch; another failure disables desired running state until the user connects
again, preventing a permanent crash loop or watchdog.

Imported profiles are treated as untrusted input even when they arrive over
HTTPS. The composer ignores user-supplied inbounds, logging, and experimental
APIs; applies per-section and per-outbound-type safe-field allowlists tied to
the exact reviewed core version; rejects unknown types, local filesystem paths,
external-process capabilities, listeners, services, and system-managed
endpoints; bounds profile and selector sizes; and then validates the composed
candidate with the exact bundled core. Runtime activation failure restores the
previous configuration and process.

The user profile store is never interpreted as an empty library merely because
it is malformed or has unsafe permissions. Invalid JSON is preserved unchanged
and reported; saving remains blocked until the user imports a corrected library
or explicitly preserves the original again and starts empty.
Clipboard diagnostics redact subscription URLs, HWIDs, proxy credentials, and
known native-profile secrets, while raw sing-box validation output is not sent
across the helper boundary.

Compact subscriptions may contain either or both supported URI protocols.
Individual `vless://`, `hysteria2://`, and `hy2://` links use the same parser
and validation path, but are stored locally and never treated as refreshable
remote sources.

Native JSON supports explicitly reviewed safe client outbound types and a
userspace WireGuard endpoint for the pinned core. Unknown future types and
fields fail closed until the capability policy is reviewed. In Rule mode the
profile owns DNS, routing, and remote rule-sets. Direct and Global are temporary
managed overrides, not edits to the imported source.

## Installation model

The distributed artifact is a drag-and-drop DMG. The app and helper are signed
ad-hoc. On first run the app registers its bundled launch daemon with
`SMAppService`; macOS remains responsible for explicit administrator approval.
No installation command or shell script is exposed to the user.

## Update model

The unprivileged app checks the public `stillnotfree/SBM` GitHub Releases API
at most once per day, or explicitly on user request. It selects only an asset
named `SBM-<version>-arm64.dmg`, requires GitHub's `sha256:` asset digest,
rejects non-HTTPS redirects and oversized responses, and independently verifies
the final file size and SHA-256 before opening the DMG.

The updater does not replace the running application or reinstall the root
helper. Ad-hoc signing makes silent self-replacement and helper mutation a poor
security boundary, so installation remains an explicit Finder operation under
macOS control.

## Validated installation behavior

The ad-hoc application has been validated on macOS 26 for the following:

1. Gatekeeper can be approved with **Open Anyway**.
2. `SMAppService` accepts the ad-hoc signed app and bundled launch daemon.
3. The approved daemon starts as root through launchd.
4. The menu app reaches the daemon without exposing arbitrary operations.
5. The app detects the exact helper revision over its authenticated local IPC
   channel. Replacing an ad-hoc-signed app may require explicit reapproval in
   Login Items & Extensions; the app never reports a helper update as complete
   until the new revision answers.
