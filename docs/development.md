# Build from source

SBM is a native Apple-silicon macOS 26+ menu-bar app. The release build contains
one pinned sing-box core. `Core.lock` records its source revision, Go compiler,
build tags, CGO mode, and linker flags. `CoreBuildInfo.swift` records the expected
core digests and matching build metadata.

## Local app build

Install Xcode command-line tools, select the Swift toolchain provided by Xcode,
and install Go with permission to download toolchains. The core recipe selects
pinned Go 1.26.10 through `GOTOOLCHAIN`. From the repository root, run:

```sh
make build
```

The recipe fetches and verifies the pinned sing-box source, builds its ARM64
binary, then builds the app and helper. `make build` writes generated outputs under
`.vendor/` and `.build/`; app and package targets write their generated outputs
under `dist/`. These commands do not install or launch SBM.

## Release package

Before the release gate, seed the pinned core in a fresh clone:

```sh
make core
make release-check TAG=v1.2.0
```

The test suite checks the generated `.vendor/sing-box` before the release packaging phase. `make build` also builds the core first. The canonical release gate then runs the serial Swift test suite, format and plist checks, diff hygiene,
ARM64 package build, signature and manifest checks, detached update-proof
verification, and DMG integrity checks. Creating release signatures requires
the project's external release key, which is not part of the repository. A
source build does not reproduce that private signature.

Never commit `.build/`, `.vendor/`, `dist/`, app bundles, DMGs, or release-key
material. See [PERFORMANCE.md](PERFORMANCE.md) for the optional read-only local
sampler.
