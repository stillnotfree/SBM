# Manual validation after installing a release candidate

Do not run these checks against an essential live VPN session. Use synthetic or
human-controlled test profiles and domains; never place credentials in reports.

## Settings UX

1. Open **Settings…** and confirm the window is resizable with Profiles,
   Routing, and Advanced tabs.
2. Profiles must show active profile, add/delete/name, source URL, Save and Sync,
   and sync status immediately. **Advanced Source Settings** starts collapsed
   and contains the filter, request headers, HWID actions, and preset reset.
3. Routing must expose Website Routing, Application Routing, and Routing
   Inspector. Raw import/open/remove controls remain under **Advanced Routing
   JSON**.
4. The subscription URL starts concealed. The eye button reveals the complete
   value for inspection/editing, hides it again, and reopening Settings starts
   concealed. A newly created Settings window should open centered; also record
   behavior after macOS restores a previously moved window.
5. Advanced must expose the staged latency interval and **Test target** rows,
   Local SOCKS5, and full native JSON import. Change values, confirm Apply is
   disabled while clean, enabled for a valid dirty draft, and disabled while an
   asynchronous apply is pending. Verify Reset to Default changes only the
   draft, and that a forced save error leaves both the draft and committed value
   visible for retry. Check resizing, focus, keyboard navigation, text selection,
   and VoiceOver labels for icon-only actions.

## Website Routing

Using non-sensitive domains chosen by the tester, validate Proxy, Direct, and
Reject for both the apex and a subdomain. Confirm a website Proxy rule overrides
a broader Direct application rule, and a website rule overrides an imported
route while mandatory private-address safety remains higher. Compare every
result with Routing Inspector, noting that hostname-only inspection can be
indeterminate when a higher `ip_is_private` rule needs the resolved IP.


## Runtime routing convergence

Use a controlled long-lived TCP/UDP transfer first; repeat with Transmission only
when appropriate. While traffic is active, change the exact application rule
through Proxy → Reject → Direct → Proxy.

A config-changing edit while the VPN is connected is intentionally **deferred**:
the helper validates and saves the desired state, keeps the known-good running
runtime and TUN untouched, and reports **Changes ready to apply**. The menu and
each visible Settings tab show one **Reconnect to Apply** action for the
deferred state. During that state, record the active TUN interface, default
routes, process traffic, and observed public egress. The edit itself must not
stop/restart sing-box, remove the managed TUN/routes, or create a physical-
interface bypass window.

Click **Reconnect to Apply** and verify that the UI enters **Reconnecting…**
and disables the action. When the VPN is running, the stop must be proven before
any start is sent; a stop failure must not start the candidate and must leave
the pending action visible. After a successful stop, the latest saved rule is
started. This is an explicit stop/start transition, not a seamless handoff or
a system-level kill-switch guarantee; the standalone TUN may have the normal
transition interval and existing TCP/UDP flows are expected to end. If start
fails, the VPN must remain disconnected, the pending action must remain
available, and there must be no automatic retry loop. Only an authoritative
running/applied status clears the pending presentation.

Verify that the latest saved rule becomes active. Reject must block newly
created matching connections after the reconnect; Direct and Proxy must apply
to newly created matching connections after the reconnect. Application
retry/backoff after Reject is application-owned and is not evidence of routing
failure by itself.

Repeat the same procedure with a website rule and while switching profiles during
an in-flight routing edit. The saved mutation must stay attached to its source
profile; changing profile B must never apply, roll back, or overwrite profile A.

While a deferred marker is present, quit/relaunch the GUI without stopping the
helper/core. Confirm the headline and the single **Reconnect to Apply** action
recover from durable state. Confirm that an authoritative active status after
relaunch does not leave a stale pending presentation. A successful reconnect
clears it; there must be no separate hidden stop-then-start action.

## Persistence and quit cleanup

1. Select a fixed server, disconnect, quit SBM, relaunch, and reconnect. The same
   server remains selected if it still exists; if a subscription refresh removed
   it, SBM falls back to Auto rather than an unknown node.
2. Use **Disconnect & Quit** and verify no SBM-owned sing-box process remains and
   managed TUN/default routes are gone. Repeat after an active session and after
   helper communication is briefly unavailable/recovered.
3. Verify the installed helper reports the expected app/helper revision after an
   upgrade. Do not treat a UI-only version string or a running process as proof;
   check authenticated status and the clean replacement/restart path.

## Manual Refresh

With multiple test subscriptions, confirm one explicit Refresh attempts every
remote source, unchanged data stays unchanged, and one failed source does not
stop the others. Repeat Refresh during the sweep and confirm no duplicate full
sweep. Confirm the UI remains responsive and Disconnect is available. If Refresh
materially changes the active profile while the VPN is connected, the new data
must be saved as desired state, the known-good runtime must remain untouched, and
the UI must report that **Reconnect to Apply** is required.
Remote rule sets must continue to follow the pinned core's `update_interval`;
this source version has no supported explicit running-core force-refresh
operation.

With a native profile that has an active remote `route.rule_set`, run Routing
Inspector against a real active cached rule set. Confirm the result comes from
the bounded cache lookup, that Explain performs no download or DNS probe, and
that a missing/unreadable cache says **active rule-set data is unavailable** with
only a bounded sanitized reason in Details.

## Real-Mac IPv6 matrix

For each observation classify the result as **INTENTIONAL DIRECT**, **PROXIED**,
**BLOCKED/FAIL-CLOSED**, or **UNEXPECTED PHYSICAL BYPASS**. Any last category is
a release blocker.

| # | Check | Expected policy |
|---|---|---|
| 1 | TUN IPv4 and IPv6 addresses | Both managed addresses present |
| 2 | IPv4 routes | Default capture through SBM while connected |
| 3 | IPv6 routes | Default capture through SBM while connected |
| 4 | Dual-stack hostname | IPv4 user traffic follows selected route; DNS strategy is IPv4-only |
| 5 | Literal public IPv6 | BLOCKED/FAIL-CLOSED before traffic sniff |
| 6 | Forced IPv6 request | Immediate local refusal; no unintended physical bypass |
| 7 | Rule mode | IPv4 Website/app/imported/final precedence preserved |
| 8 | Global mode | IPv4 PROXIED; IPv6 BLOCKED/FAIL-CLOSED |
| 9 | Direct mode | IPv4 INTENTIONAL DIRECT; IPv6 BLOCKED/FAIL-CLOSED |
| 10 | Compatibility profile | Same capture and mode semantics |
| 11 | Native profile | Same app-owned TUN and safety semantics |
| 12 | Website Proxy | IPv4 PROXIED for apex and subdomain; IPv6 BLOCKED/FAIL-CLOSED |
| 13 | Website Direct | IPv4 INTENTIONAL DIRECT; IPv6 BLOCKED/FAIL-CLOSED |
| 14 | Website Reject | BLOCKED/FAIL-CLOSED |
| 15 | Application Routing | IPv4 target policy applies to exact executable; IPv6 blocked before app rule |
| 16 | Wi-Fi/network transition | Re-converges without physical IPv6 bypass; IPv6 remains blocked |
| 17 | Sleep/wake | Re-converges without physical IPv6 bypass; IPv6 remains blocked |
| 18 | Disconnect cleanup | Managed IPv4/IPv6 routes and TUN removed |

REAL-MAC LIVE IPv6 VALIDATION:
NOT PERFORMED — CURRENT VPN MUST REMAIN ONLINE
