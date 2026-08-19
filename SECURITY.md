# Security policy

## Supported versions

Security fixes are provided for the latest published Marina release.

## Report a vulnerability

Do not open a public issue for a security vulnerability. Report it privately to the project maintainers with:

- the affected version;
- clear reproduction steps;
- the expected and observed behavior;
- the practical impact;
- any suggested mitigation.

You should receive an acknowledgment within 72 hours. Please allow time for a fix and coordinated disclosure before publishing details.

## Security model

Marina can start and stop local processes, read their output, and hold their
environment variables. Its control API is therefore treated as a privileged
interface, not as a convenience endpoint.

### Trust boundary

The API binds to `127.0.0.1:7737` only. Loopback alone is not a trust boundary:
the user's own browser sits on the same interface, and any page can send a
cross-origin request to it. The listener therefore applies four checks before a
route runs.

1. **No browser-originated requests.** A request carrying `Origin`, `Cookie`, or
   any `Sec-Fetch-Site`/`Sec-Fetch-Mode`/`Sec-Fetch-Dest` header is refused with
   `403`. That covers CSRF from a malicious page, including "simple" requests
   that avoid a CORS preflight.
2. **Host validation.** Only `127.0.0.1:7737`, `localhost:7737`, and
   `[::1]:7737` are accepted, which defeats DNS rebinding.
3. **JSON-only bodies.** A request with a body must declare
   `application/json`; `text/plain` and the form content types are refused with
   `415`. Those are exactly the types a browser can send without a preflight.
4. **Bearer token.** Every route that can read secrets or run a command requires
   `Authorization: Bearer <token>`, compared in constant time.

No response ever carries `Access-Control-Allow-Origin`, so a browser cannot read
a reply even if a request slipped through. Requests are capped at 1 MB and
connections time out after 15 seconds.

### The token

The token is 32 bytes from `SecRandomCopyBytes`, hex-encoded, stored at
`~/.config/marina/token` with mode `0600` inside a `0700` directory. It is
created on first launch and never rotated automatically. The CLI reads it
transparently; `MARINA_TOKEN` overrides the file for other callers.

The token is not a defense against other processes running as the same user —
those can read the file, and `config.json` directly. It defends against callers
that can reach the port but not the filesystem: browsers, and sandboxed
processes.

### Documented exception

`/ping`, `/status`, `/start`, `/stop`, and `/restart` are reachable without the
token. The sandboxed App Store companion is the reason: it cannot read
`~/.config/marina/token`. None of these routes can read an environment, read a
log, or run a new command. Adding a route to that allowlist requires security
review.

### No outbound network

Marina makes no request of its own to anything but `127.0.0.1`. There is no
update framework, no update feed, and no analytics in the app. The only
addresses present in the built binary are `http://127.0.0.1` and
`http://localhost`, and a running Marina holds exactly one socket: its own
loopback listener.

`Tests/MarinaAppTests/LocalOnlyTests.swift` enforces this by reading the shipped
sources: it fails if any source file names a non-loopback host, if an update
framework is imported or declared in `Package.swift`, if `build.sh` writes an
update-feed key into the bundle, or if analytics code reappears. Adding an
outbound request of any kind requires explicit security review.

Two network paths remain, both user-initiated: a server's `healthURL` is fetched
exactly as configured, so a full remote URL is requested as written; and the
supervised servers are the user's own processes, which Marina neither proxies nor
inspects.

### Data at rest

`config.json` holds every server's environment variables in cleartext, and the
files under `logs/` hold process output. Both are written at mode `0600` in a
`0700` directory, and a server's log files are deleted when the server or its
project is removed. Log content is **not** redacted: a secret echoed by a dev
server appears in `marina logs`, which is intentional so debugging output stays
faithful. Treat log output as sensitive, in particular before pasting it into an
AI agent's context.

### Review triggers

Changes require explicit security review when they expose the API beyond
loopback, widen the token-free allowlist, relax any of the four request checks,
add a CORS header, execute untrusted commands, or make any outbound request --
including an update check, a crash report, or a usage statistic.
