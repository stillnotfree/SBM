# Performance baseline protocol

`scripts/performance-baseline.swift` is a macOS-only, read-only sampler for a
small, caller-specified set of process IDs. It exists to collect a reproducible
local baseline; it does not optimize SBM and this repository does not yet make a
general CPU, memory, or wakeup claim.

The sampler does not find processes by name, start or stop them, inspect their
configuration, connect to their sockets, or alter their priority. Give it the
PIDs that you independently verified in Activity Monitor or another local
observer. Use distinct labels for the SBM app, privileged helper, and sing-box
core because they are separate processes with separate counters.

## Requirements and output

- Run on macOS as a user permitted to read the chosen processes' public
  `proc_pid_rusage` data. No VPN process should be needed to test argument
  validation or `--help`.
- Run from a checkout with the Apple Swift toolchain:

  ```sh
  ./scripts/performance-baseline.swift --help
  ```

- Supply one to three `LABEL=PID` values. Labels are deliberately restricted to
  ASCII letters, digits, `.`, `_`, and `-`; a PID and label each appear only
  once. Duration is 1--3600 seconds; interval is 1--60 seconds and cannot
  exceed duration.
- JSON Lines is written only to standard output. Redirect it if a file is
  wanted; the script itself never creates or changes a file.

  ```sh
  mkdir -p measurements
  ./scripts/performance-baseline.swift \
    --duration 300 --interval 5 \
    --target app=123 --target helper=456 --target core=789 \
    > measurements/idle-a-01.jsonl
  ```

The first line is a versioned `header`; remaining lines are `sample` records in
caller order at elapsed zero and each requested interval. Every record is
JSON-encoded with stable key ordering. A sample contains the public
`rusage_info_v2` resident size, cumulative user and system CPU nanoseconds,
their cumulative sum, package-idle wakeups, and interrupt wakeups. It also
contains the public process UUID and start absolute time used to reject a PID
that is reused during the run.

The sampler fails on PID exit, PID reuse, inaccessible metrics, or an invalid
argument. Treat a failed file as invalid; do not join it to another run.

## Measurement procedure

Keep the machine, profile, target URL, network, and SBM build fixed within one
comparison. Record the macOS version, hardware, app build, core version, power
state, display/sleep state, active profile and route mode separately from the
JSONL. Do not include subscription URLs, credentials, or profile contents.

For every scenario:

1. Reboot only if it is part of both sides of the comparison. Close unrelated
   apps, pause backups/indexing/sync, keep the power source and display state
   unchanged, and avoid software updates during the series.
2. Establish the stated SBM condition manually, then warm it for 120 seconds.
   Do not count that warm-up in the result.
3. Start the sampler with a five-minute (`--duration 300 --interval 5`) run.
   This yields 61 readings per target. Do not change the condition while it is
   running.
4. Repeat at least five times, alternating A and B runs when comparing builds
   or configurations. Keep the raw JSONL files.

Use these three conditions. They are intentionally application-level scenarios;
the harness does not operate SBM for you.

| Scenario | Manual condition during the five-minute run |
| --- | --- |
| Idle | SBM open and disconnected; no profile refresh, update check, or manual latency action. |
| Connected | SBM connected to the same selected profile and route mode; leave user traffic quiet except for ordinary background macOS noise. |
| Latency test | The same connected state; invoke SBM's manual latency test at a pre-recorded cadence (for example, once at 60, 120, 180, and 240 seconds). Record the cadence and target URL next to the run. |

For A/B work, change exactly one named variable, repeat the same sequence, and
use the same explicit labels on both sides. For example, after independently
recording PIDs for each side:

```sh
./scripts/performance-baseline.swift --duration 300 --interval 5 \
  --target app=123 --target helper=456 --target core=789 \
  > measurements/connected-a-01.jsonl

./scripts/performance-baseline.swift --duration 300 --interval 5 \
  --target app=223 --target helper=556 --target core=889 \
  > measurements/connected-b-01.jsonl
```

## Comparing files

Compute each process independently. Do not silently sum app, helper, and core:
report the three readings and, if a total is useful, label it as an explicit
sum of the sampled processes.

- CPU time delta: last `cpu_total_nanoseconds` minus first; divide by elapsed
  wall seconds for CPU-seconds/second, or multiply that ratio by 100 for a
  single-process CPU percentage. It may exceed 100 for a multithreaded process.
- Wakeup deltas: last minus first for `package_idle_wakeups` and separately for
  `interrupt_wakeups`; divide each by elapsed wall seconds. Do not add them
  unless the report explicitly says that it uses that nonstandard combined
  number.
- Memory: retain every `resident_memory_bytes` observation. Report a run's
  median and maximum; do not infer a leak from one five-minute trace.
- Across the five or more repeated runs, compare the median of each per-run
  value. For a within-run p95, sort the 61 observations and use nearest rank
  `ceil(0.95 * n)` (rank 58 for 61 readings). State whether a reported p95 is
  over raw observations or over per-run values.

`ri_resident_size` is the kernel's resident-size counter, not a guarantee of
private physical footprint or system-wide RAM. CPU and wakeup counters are
cumulative per-process kernel accounting, not a complete energy measurement.
The public API exposes package-idle and interrupt wakeups separately; it does
not provide a portable, universal "total wakeups" metric, so this protocol does
not invent one. It also does not attribute child processes to the app, measure
network throughput, latency quality, TUN packet cost, or system-wide power.

A local snapshot is evidence only for the stated machine, build, profile,
network, and procedure. It is not a universal SBM performance claim.

## Responsiveness invariants

Latency work is issued as bounded, cancellation-aware per-node control requests,
and explicit Disconnect cancels the sweep before submitting the next runtime
mutation. Manual subscription Refresh is one coalesced bounded sweep and does
not disable Disconnect. These changes are **MECHANICALLY REQUIRED FOR
RESPONSIVENESS**; they do not by themselves establish a CPU, memory, battery,
network-latency, or throughput improvement. Any such claim still requires the
measurement protocol above.
