# Third-party software

## sing-box

This project builds an SBM-specific Apple Silicon sing-box binary from the
exact upstream source revision recorded in `Core.lock`; it does not package the
official prebuilt sing-box binary.
The application icon uses the official sing-box parcel artwork from the same
upstream project and lets macOS render its native glass, dark, clear, and tinted
appearances.

- Upstream: <https://github.com/SagerNet/sing-box>
- Version: 1.14.4
- License: GNU General Public License v3.0 or later, with the additional naming
  restriction stated by the upstream project.

The build uses the upstream source and license without modifying the sing-box
source tree. Build tags and toolchain are limited to the reviewed SBM recipe in
`Core.lock`.
