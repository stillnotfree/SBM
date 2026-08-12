Telegram observations are evidence, not specification.

# Russia network findings

## Evidence classes

- **Confirmed product fact:** behavior traced in SBM or the exact locked
  sing-box source and covered by a reproducible check.
- **User A/B observation:** a reported comparison with enough context to be
  useful, but not necessarily controlled or generalizable.
- **Hypothesis:** a plausible explanation that still needs an isolating test.
- **Folklore:** a repeated claim without sufficient context or reproduction.

Only the first class defines implementation behavior. The other classes can
suggest tests, UI explanations, and explicit limitations.

## Concise evidence

### There is no universal protocol winner

Project VLESS message 489201 and Amnezia message 1193369 report different
protocol outcomes in different conditions. These are user observations, not a
ranking that SBM can safely encode. Protocol choice remains explicit; SBM does
not silently fall back, rotate, or claim one transport works everywhere.

### Address and path are separate failure domains

Amnezia messages 1413755, 1333244, and 1333247 and Project VLESS message 457254
describe outcomes changing with IP address, route, ISP, region, or ASN. Treat
those variables separately from protocol syntax. A failed endpoint does not by
itself prove that every endpoint using the same protocol is blocked.

### A handshake is not a healthy data plane

Amnezia message 1264419 and the associated report describe connections that
complete an initial handshake but do not carry useful traffic reliably. A TCP,
TLS, or protocol handshake is therefore not sufficient evidence of working
DNS, throughput, sustained transfer, or bidirectional TUN traffic.

### The client implementation is a failure domain

Amnezia message 1215239 and Project VLESS message 454223 report different
results across clients using nominally similar profiles. Parser semantics,
defaults, DNS, routing composition, core version, and lifecycle behavior must
be isolated before attributing a failure solely to a protocol or network.

### XHTTP and XMUX are not universal remedies

Project VLESS messages 499418, 476310, 441857, and 494232 contain mixed or
conditional observations around XHTTP/XMUX. They do not justify silently
mapping XHTTP to TCP, enabling XMUX globally, or adding a second core. SBM must
reject unsupported direct links explicitly and keep imported capabilities tied
to the exact reviewed sing-box version.

### Routing lists have false positives and stale entries

Antifilter messages 49040 and 46301, RoscomVPN message 5280, and related reports
show that large maintained lists can contain false positives, omissions, or
stale classifications. SBM should not bundle a huge Russia list or treat a
remote list as ground truth. User-owned rules remain visible, ordered, and
replaceable; safety policy still fails closed.

## What this does not justify

The evidence above does not support global defaults for FakeIP, MTU, mux,
keepalive, fragmentation, fingerprint rotation, or protocol fallback. Each can
change failure modes and privacy properties. Adopt one only after a concrete
SBM problem has a reproducible A/B result and the exact core behavior is
verified.

It also does not justify DPI detection, traffic inspection, nDPI/Suricata,
telemetry, access logs, WARP integration, or automatic censorship diagnosis.
SBM remains a small client that composes explicit policy and reports known
state without pretending to infer the network's intent.

## Using new observations

Record the client and core versions, profile semantics without secrets, ISP,
region, endpoint ASN, IP family, DNS path, test time, and exact success metric.
Change one variable at a time. Label the result as an observation until it is
reproduced; label an explanation as a hypothesis until an isolating test
supports it.
