# Security

Homeswift pairs with HomeKit controllers, keeps their keys, and runs a web UI, an OAuth server and an MCP server
that can change devices, locks included. A flaw in any of them matters, so please report it privately.

## Reporting a vulnerability

Use [Report a vulnerability](https://github.com/mp-consulting/homeswift/security/advisories/new) on the repository's
Security tab. Do not open a public issue, pull request or discussion for it.

Say what is affected (the version, the plugin or the component: pairing, sessions, the web UI, OAuth, MCP, the
Assistant), how to reproduce it, and what an attacker gains. A proof of concept helps; keep real setup codes, keys and
tokens out of it.

You get an answer within a week. We agree on a fix and a date with you, publish an advisory with the release that
fixes it, and credit you unless you prefer otherwise.

## Supported versions

Fixes go into the latest release. Update to it before reporting, if you can.

## Scope

In scope: this repository's code, the plugins under `Plugins/`, the container image on GHCR and the Synology package.

Out of scope: a device's or a cloud's own flaws (report those to its maker), attacks that need the bridge's
configuration directory or an administrator account already, and HomeKit itself (report those to Apple).
