# Security Policy

## Supported versions

Only the latest published version of Screening Automation receives security
fixes. Older releases should be upgraded before reporting a problem that may
already be resolved.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting form:

https://github.com/686f6c61/macOS-screaning-automation/security/advisories/new

Do not include exploit details, private keys, screenshots containing personal
data, or other sensitive evidence in a public issue. Include the affected
version, macOS version, reproduction steps, impact, and any suggested fix in the
private report.

An initial acknowledgement is expected within seven days. Valid reports will be
handled through a private advisory until a fix and coordinated disclosure are
ready.

## Release trust

Official releases are expected to be:

- built by the protected GitHub `release` Environment;
- signed with Apple Developer ID and Hardened Runtime;
- notarized and accepted by Gatekeeper;
- distributed through an immutable GitHub Release;
- signed with the Sparkle EdDSA key; and
- accompanied by a Homebrew cask containing the exact SHA-256 checksum.

If any of these properties is missing, do not install the artifact and open a
private report.
