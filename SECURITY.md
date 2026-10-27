# Security policy and PR review checks

## Reporting a vulnerability

Do not put credentials, private note contents, or sensitive exploit details in
public issues or PR comments. If this repository's GitHub Security tab offers
**Report a vulnerability**, use that private reporting channel. If it is not
available, ask a maintainer to establish a private channel before sharing details;
a public request should contain no vulnerability specifics.

Include the affected commit or version, prerequisites, impact, and minimal
reproduction steps using synthetic data. Redact secrets and personal information.
This document does not establish a supported-release matrix or response-time
commitment.

## Current security context

- The core stores notes as JSON at
  `~/Library/Application Support/Webby/notes.json`. It does not implement
  application-level encryption. Corrupt-file backups can also contain note data.
- The Chrome extension requests `tabs`, `nativeMessaging` and `storage`. It sends
  tab URLs and titles to the native messaging executable, which checks the caller
  origin and relays them to the app over a Unix socket at
  `~/Library/Application Support/Webby/bridge.sock` (mode 0600; the app accepts
  only peers with the current user's uid). URLs and titles are kept in memory and
  logged only as private values; nothing writes them to disk yet.
- The app writes Chrome's native host manifest, and the template documents it. Both
  restrict `allowed_origins` to the extension's ID.
  The manifest's `key` is a public key used to derive that ID, not a private secret.
- Local packaging produces an ad-hoc signed app, not a notarized distribution.

Review changes against the actual implementation. Apply the checks below when a
PR touches or introduces the corresponding capability; they are not claims that
every capability is present.

## Security checks for pull requests

### Notes and sensitive data

- Trace note text, URLs, local paths, and app context through storage, logs,
  diagnostics, and any network requests. Avoid unnecessary collection or exposure.
- Review new telemetry, remote services, or exports for explicit user control,
  minimal data transfer, and clear failure behavior.
- Preserve atomic writes and recoverable originals. Check migrations, malformed
  files, backup collisions, and deletion behavior for loss or unintended retention.
- Check file permissions and path handling when storage changes. Untrusted input
  must not select arbitrary files to read, overwrite, or delete.
- Never commit credentials, signing private keys, tokens, or real user data.
  Use synthetic fixtures and redact sensitive values in review evidence.

### Browser and native messaging boundaries

- Justify additional extension permissions and host access. Keep native host
  origins restricted to intended extension IDs and verify identity consistency.
- Treat browser messages as untrusted input. Validate message type, required
  fields, lengths, and allowed values before using them.
- For native messaging implementation, check framing, bounded message sizes,
  partial reads, malformed JSON, EOF, and disconnect handling. Keep diagnostic
  output off protocol stdout.
- Review any local IPC for caller access restrictions and bounded input handling.
  Do not interpolate message values into shell commands or executable paths.
- Treat URL normalization as display matching, not an authorization boundary.
  Scheme/query stripping or host grouping must not grant access to unrelated data.
  File URLs must not implicitly authorize reading local files.

### macOS permissions and capture

- Check that new Accessibility, screen, or microphone access is necessary for
  the requested feature and respects permission denial and revocation.
- Capture only within the user's intended scope. Ensure permission or capture
  failure does not silently broaden access or discard notes.
- Review subprocess arguments, executable selection, and installation paths for
  injection or unintended privilege use.

### AI and external services

- If introduced, treat notes, web pages, and captured content as untrusted data,
  not instructions that can authorize tool use or disclose other data.
- Verify that retrieved context and actions stay within the authorized user and
  workspace scope. Check stale or deleted data handling and provider-bound secrets.
- Make transfers of note, screen, or audio content explicit and scoped. Check
  retention and failure behavior without assuming a provider or cloud backend.

### CI, dependencies, and distribution

- Inspect workflow trigger, token permission, secret access, and artifact changes.
  Untrusted PR code must not run with privileged credentials; pay particular
  attention to `pull_request_target` combined with PR code checkout or execution.
- Review new dependencies and build-time downloads for provenance and integrity.
  Avoid exposing secrets in logs, caches, or uploaded artifacts.
- Verify packaging and signing claims against the build scripts. Ad-hoc signing
  must not be presented as notarization or verified publisher identity.

## Evidence and handling

Security findings should identify a reachable path, attacker-controlled input or
relevant failure condition, affected data or capability, and concrete impact.
Distinguish demonstrated defects from questions requiring more evidence. Use
isolated tests and synthetic data; do not exploit live users or external systems.
Keep sensitive reproduction details in a private reporting channel.
