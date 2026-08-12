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

The UI serializes runtime-changing requests through a generation-ordered apply
coordinator. A stale response may update observations but cannot overwrite the
new desired profile, mode, or node. If profile, routing, mode, or node changes
while `start` is in flight, the pending operation is replaced by one complete
start snapshot containing the latest profile, mode, and node. The UI reports
saved, applying, active, and failed states separately.

Imported profiles are treated as untrusted input even when they arrive over
HTTPS. The composer ignores user-supplied inbounds, logging, and experimental
APIs; applies per-section and per-outbound-type safe-field allowlists tied to
the exact reviewed core version; rejects unknown types, local filesystem paths,
external-process capabilities, listeners, services, and system-managed
endpoints; bounds profile and selector sizes; and then validates the composed
candidate with the exact bundled core. The helper validates the complete
candidate with its new API secret and stages the current configuration backup
before stopping a healthy core. Every failure after the transition begins
restores the previous configuration and process; a PID is removed only after
the old process is confirmed stopped.

The user profile store is never interpreted as an empty library merely because
it is malformed or has unsafe permissions. Invalid JSON is preserved unchanged
and reported; saving remains blocked until the user imports a corrected library
or explicitly preserves the original again and starts empty.
Clipboard diagnostics redact subscription URLs, HWIDs, proxy credentials, and
known native-profile secrets, while raw sing-box validation output is not sent
across the helper boundary.

The Diagnostics window creates a bounded versioned support snapshot from state
the UI already holds. Text and sorted-key JSON copies contain observations, not
DNS or network-health results: they never start a latency test, read logs,
discover processes, contact the network, or export profiles/configuration.
The snapshot omits profile/source/node names and IDs, URLs, request headers,
HWIDs, credentials, and raw native JSON; protocol counts and summary delay
observations are retained only in capped aggregate form.

The latency target is one user-configurable absolute HTTPS URL. It is limited,
validated without credentials, fragments, or control characters, and persisted
by both the user library and root helper state. Applying it sends no VPN
lifecycle action: manual delay tests use it immediately through each selected
proxy, while SBM-created `urltest` groups use it on the next normal start.
Imported native `urltest` outbounds remain profile-owned and unchanged. The
target host therefore sees a request through every tested proxy; no latency
telemetry is collected or exported.

Managed compatibility profiles store one typed connection list. Each connection
has a persistent node ID, a UI name, and a VLESS+REALITY, Hysteria2, or
Shadowsocks outbound. Source refreshes reconcile IDs by endpoint and credential
semantics, not by a mutable display name; duplicate connections consume prior
IDs in source order. Source groups and helper selector tags use those IDs
directly. A renamed source therefore does not restart a running core by itself.

The profile-store schema-1 migration reconstructs the v1.1.11 aggregate order and
preserves its `vless-N` / `hysteria2-N` IDs for active legacy nodes before the
rewritten library is used. Entries which were excluded from the old aggregate
receive fresh `node-UUID` IDs, so a later filter change cannot alias a live
node. Newly parsed connections use `node-v1-` plus SHA-256 over a versioned,
length-delimited canonical semantic identity. The digest hides readable
credentials while changing when endpoint or credential semantics change;
display name and source order are excluded. Schema 3 adds application rules to
schema 2 without rewriting managed IDs. The helper validates every managed
tag as unique ASCII `[A-Za-z0-9._-]`, bounded, and non-`auto`; groups must have
unique IDs and refer only to those validated node IDs.

Per-application routing stores the selected `.app` bundle and its exact main
executable path. The app never scans a bundle or matches a process by display
name. Moved, deleted, or changed bundles remain visible but unresolved; fixed
node targets also become inactive when their stable node disappears. The
helper validates bounded absolute paths and requires the executable path to be
lexically inside the `.app`, then emits exact `process_path` rules after SBM's
safety rules and before imported routing. DIRECT and PROXY targets use a route
outbound; REJECT emits the native terminal `action: reject` without a fake
outbound. The feature changes traffic routing, not DNS policy. Routing
Inspector treats configured application rules as not
matched for `Default traffic`, or evaluates them against the exact path of the
selected configured application. Unrelated imported process conditions remain
unresolved when the selected context cannot determine them.
Remote rule-set explanations use a bounded helper request against the active
profile only. The helper reads one tag from sing-box's root-owned bbolt cache
with strict page, checksum, key, and size bounds, writes a root-only temporary
copy, and invokes the verified core's `rule-set match` command. Rule-set bytes
and core output never cross IPC; a missing, changing, malformed, or inactive
cache fails closed.

New subscription sources reproduce the exact `User-Agent`, `X-App-Version`, and
`X-Device-OS` client-identification fields from a user-captured Happ 5.4.0 iOS
request. Per-device model, OS version, locale, and transport headers are not
invented. New HWIDs use the observed 16-character lowercase-alphanumeric shape,
without claiming the same internal generator. Existing or custom headers are
not migrated. Reset changes only the request preset and preserves the source
HWID. Provider-identification and sensitive headers are stripped after a
cross-origin redirect.

Compact subscriptions may contain any mix of supported URI protocols.
Individual `vless://`, `hysteria2://`, `hy2://`, and strict plugin-free
SIP002 `ss://` links use the same parser and validation path, but are stored
locally and never treated as refreshable remote sources. Shadowsocks accepts
only the reviewed AEAD/2022 cipher allowlist, no query or plugin, and no
whole-URI legacy Base64 form. 2022 credentials are plain URI userinfo carrying
a canonical Base64 PSK of the method's required decoded size; encoded userinfo
is rejected for that family.

`ManagedConnection.displayName` is the authoritative UI name. VLESS and
Hysteria2 payload types still retain a duplicate legacy name field solely for
old JSON decoding and source compatibility; configuration, groups, and menus
use the wrapper name. It is a bounded compatibility compromise, not a second
identity key.

Native JSON supports explicitly reviewed safe client outbound types and a
userspace WireGuard endpoint for the pinned core. Unknown future types and
fields fail closed until the capability policy is reviewed. In Rule mode the
profile owns DNS, routing, and remote rule-sets. Direct and Global are temporary
managed overrides, not edits to the imported source.

## Installation model

The distributed artifact is a drag-and-drop DMG. The app and helper are signed
ad-hoc. On first run the app registers its bundled launch daemon with
`SMAppService`; macOS remains responsible for explicit administrator approval.
No installation command or shell script is exposed to the user. While an
explicitly initiated approval flow is pending, SBM persists only that intent,
rechecks `SMAppService.status` when the app becomes active, and uses a bounded
temporary status poll. Once macOS reports the service enabled, SBM verifies the
exact helper version and revision over authenticated IPC and invokes the
existing verified replacement flow only when the installed helper is not
current. Approval is never inferred from elapsed time or process existence.

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
