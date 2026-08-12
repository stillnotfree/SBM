# Development

## Scope

SBM is a native Apple-silicon, macOS 26+ menu-bar application. The app is
unprivileged; its versioned launchd helper validates configuration and owns one
protected sing-box TUN runtime. Start with `AGENTS.md`, `ARCHITECTURE.md`, and
`SECURITY.md` before changing this boundary.

## Local workflow

Record the existing tree before editing:

```sh
git status --short
git diff --check
```

Trace the current behavior and add a deterministic regression before fixing a
confirmed defect. Prefer focused tests while iterating, then run:

```sh
swift test
xcrun swift-format lint --recursive Sources Tests Package.swift
plutil -lint Resources/Info.plist Resources/com.stillnotfree.sbm.helper.plist
git diff --check
```

`make app` creates the local ARM64 application at `dist/SBM.app`. It does not
install or launch it. Do not use development verification to stop, replace, or
probe an installed SBM, helper, or sing-box process.

## Core update

`Core.lock` is the source of truth for the exact reviewed stable sing-box
release and its upstream input digests. Update it only from the repository root:

```sh
scripts/update-core.swift stable
```

`make core` downloads only the locked archive when needed, verifies the archive
and extracted ARM64 binary, signs the exact bundled copy, and regenerates
`Sources/SBMShared/CoreBuildInfo.swift`. `.vendor/` is generated and must not be
edited or committed.

Any newly used core field or behavior requires review against the exact locked
version. Future or unknown capabilities remain unsupported until explicitly
reviewed and tested.

## Generated and local artifacts

These are local outputs and stay out of commits:

- `.build/`, `.swiftpm/`, and `.vendor/`;
- `dist/`, application bundles, DMGs, and checksum sidecars;
- `.DS_Store` and local `.codex/` review material.

`Resources/Info.plist`, the helper launchd plist, `Core.lock`, and source files
are inputs, not disposable build output.

## Release preflight

Set the version consistently in the tracked metadata before running the gate:

```sh
make release-check TAG=vX.Y.Z
```

The preflight verifies metadata, tests, formatting, plists, diff hygiene, the
release build, ARM64 architecture, bundled core identity, and signatures. It is
strictly local: it does not commit, push, tag, install, launch, or publish.

Publishing is a separate explicitly authorized operation. Review the complete
diff, exclude `.codex/` and local artifacts, then create a DMG and SHA-256 for
the exact tagged commit.

## Testing boundaries

Unit tests should use synthetic credentials, loopback addresses, temporary
directories, and injected platform seams. They must not contact real providers,
read installed root state, or control launchd.

A passing local build proves only source and artifact checks. Finder behavior,
window level, background-item approval, ISP behavior, and live VPN connectivity
need separately reported manual evidence. Never imply those checks ran when
they did not.

## Performance

Do not tune MTU, mux, keepalive, FakeIP, concurrency, or protocol selection from
anecdotes. Use the bounded sampler and A/B procedure in `PERFORMANCE.md`.
Report the machine, build, profile, network, sample duration, and variance; a
single local measurement is not a general performance claim.
