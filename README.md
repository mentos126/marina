# Marina

Marina is a native macOS supervisor for local development servers. It keeps each command in a real interactive PTY, checks its port, restarts it after crashes, and exposes the same controls through a menu bar app, a CLI, and a loopback-only HTTP API.

Use persistent projects for long-lived, reusable services. Use top-level **Temporary** jobs for builds, tests, one-off previews, demos, generated artifacts, and short tasks; they run in the background with a deadline, expose their logs and exit code, and are never restored on the next launch.

Marina requires macOS 14 or newer and Swift 6.

## Smart resource dashboard

The native **Resources** screen samples every Marina-owned process tree every two seconds while it is on screen, and keeps a five-minute memory history. It shows physical footprint, resident RAM, CPU, project trends, and the current user's heaviest processes running outside Marina. Configure the optional global project limit and per-project inherit/off/custom overrides in **Settings → Memory**. A project restarts after three consecutive over-limit footprint samples, then sampling starts fresh on the replacement processes.

Marina turns those measurements into machine-aware recommendations instead of relying on one fixed limit. It detects unusually large servers and processes, sustained growth while ignoring isolated build spikes, and duplicate dev sessions outside Marina. Advice is tailored to common Next.js, Vite, Node, TypeScript, browser, Docker, Redis, and Postgres failure modes. Managed servers can be restarted or stopped from the recommendation card. External process cards show the validated stop target, parent, working directory, listening ports, and the difference between footprint and resident RAM; an explicit confirmation can send SIGTERM, but Marina never terminates them automatically or escalates to SIGKILL.

When Docker Desktop owns a published host port, Marina resolves the actual container through the Docker CLI. **Stop** and **Move to Marina** stop only that container instead of signaling the global `com.docker.backend` process.

## Energy

Marina is meant to run all day, so it samples only for a reader that exists. Each sample spawns `/bin/ps` across the whole process table, and the working-directory and listener enrichment adds two `lsof` calls that walk every file descriptor on the machine. The cadence follows what is actually on screen:

| Situation | Sampling |
| --- | --- |
| Resources screen visible | every 2s, with the `lsof` enrichment |
| A window visible on another screen | every 6s, no enrichment |
| A project memory limit is armed | every 5s, no enrichment |
| Menu bar only, servers running | every 15s, no enrichment |
| Nothing running and nothing on screen | suspended |
| Display or machine asleep | suspended |

Low Power Mode halves every rate and drops the enrichment. The Ports screen stops its own `lsof` loop when its window is hidden. Every timer carries a tolerance so macOS can coalesce Marina's wakeups with ones it already has to make instead of interrupting an idle core on an exact deadline.

Metrics still reach the CLI: `marina status` counts as a reader, refreshing a sample the idle cadence let age and keeping the sampler warm for a minute so a polling agent reads fresh numbers.

## Install

```bash
./build.sh --run
```

This builds and ad-hoc signs `Marina.app`, installs it in `/Applications`, installs `marina` in the first writable bin directory on `PATH`, installs the bundled skill in `~/.agents/skills/marina`, adds idempotent Marina server-management rules to `~/.agents/AGENTS.md`, and launches the app. Reinstalling quits the running app first, which stops every server supervised by Marina. Public GitHub releases are signed with Developer ID and notarized by Apple.

People who download the signed macOS app can complete the same agent setup from the onboarding card at the top of Marina. It installs the bundled skill and CLI, then adds marker-delimited global rules to `~/.agents/AGENTS.md` and `~/.claude/CLAUDE.md` without replacing existing instructions.

To launch Marina automatically at every macOS login, use:

```bash
./build.sh --forever
marina forever status --json
```

`marina forever enable` preserves and restarts the servers that were active during the handoff to `launchd`. `marina forever disable` removes the LaunchAgent recoverably and leaves active servers running under a regular Marina launch. This mode supervises the macOS app; Linux requires a separate headless daemon because SwiftUI/AppKit cannot run there.

Use `./build.sh --no-install` to assemble `dist/Marina.app` without installing it.

## Updates and releases

Marina does not check for updates. It has no update framework, no update feed, and it never contacts a release server -- see [Privacy](#privacy). The installed version is visible in Settings and in the standard About window; to move to a newer one, download it and replace the app.

To publish a new version, update the single value in `Sources/MarinaCore/Version.swift`, commit and push it, then run:

```bash
./release.sh 0.1.2
```

The release script builds a universal Apple silicon and Intel binary from the pushed commit. It creates a hardened-runtime Developer ID build, submits it to Apple for notarization, staples the ticket, and publishes `Marina-macOS.zip` to a versioned GitHub release.

## Privacy

Marina is local-only. It sends no analytics, checks for no updates, and makes no request of its own to any host other than `127.0.0.1`. There is no telemetry to turn off because there is none to send.

The only addresses that appear anywhere in the built binary are `http://127.0.0.1` and `http://localhost`:

```bash
strings -a /Applications/Marina.app/Contents/MacOS/Marina | grep -Eo 'https?://[a-zA-Z0-9.-]+' | sort -u
```

You can confirm it at runtime too -- the app holds exactly one socket, its own loopback listener:

```bash
lsof -nP -i -a -p "$(pgrep -x Marina)"
```

`Tests/MarinaAppTests/LocalOnlyTests.swift` enforces this in CI: it fails the build if any source file names a non-loopback host, imports an update framework, or references analytics.

Two things do use the network, and both are yours to trigger:

- A server's `healthURL` is fetched as you configure it. A path such as `/api/health` stays on `localhost`; a full remote URL is requested as written, because you asked for that check.
- The servers Marina supervises are your own processes and make whatever calls they make. Marina does not proxy or inspect them.

## CLI

Every CLI command launches Marina automatically when it is closed. `status` is compact by default: it shows only active servers and problems. Use `--details` for the full human inventory and `--json` for complete machine-readable data.

```bash
marina status
marina status --details
marina status --json

marina memory-limit 5GB
marina memory-limit 3GB --project lumail.io
marina memory-limit inherit --project lumail.io
marina memory-limit off

job_id="$(marina temp 'npm run build' --timeout 20m)"
marina wait "$job_id"

marina temp 'npm run dev -- --host 127.0.0.1 --port 5180' \
  --name transcript-preview \
  --path /path/to/generated/transcript \
  --port 5180 \
  --timeout 1h

marina add-project \
  --name codelynx \
  --path ~/Developer/projects/codelynx.dev-v2 \
  --icon globe \
  --color '#0A84FF' \
  --json

marina add-server \
  --project codelynx \
  --name web \
  --command 'pnpm dev' \
  --port 5173 \
  --start \
  --json

marina logs codelynx/web --tail 100
marina restart codelynx/web --json
marina update-server codelynx/web --action 'clear-cache=trash .next/cache'
job_id="$(marina action codelynx/web clear-cache)"
marina wait "$job_id"
marina take-over codelynx/web --json
marina stop --project codelynx --json
```

Other commands are `temp` (`temporary`, `run-temp`), `wait`, `action`, `memory-limit` (`ram-limit`), `start`, `stop`, `restart`, `take-over` (`adopt`), `update-server`, `remove`, `port`, `kill-port`, `open`, `quit`, `forever`, and `config`. `temp` returns a job ID immediately; `wait` blocks for that ID and exits with the job's real exit code (`124` for timeout). `action` runs a configured maintenance command beside a server without restarting it. `memory-limit` shows or changes the global default and project overrides; it is off by default. `take-over` stops an external listener on the configured port and relaunches the server under Marina. `forever` manages the per-user macOS LaunchAgent. Run `marina <command> --help` for exact flags. `quit` stops every managed server because the app is the supervisor.

## Configuration

Marina stores its source of truth in `~/.config/marina/config.json` and watches the file for external changes. Server logs live in `~/.config/marina/logs/`.

Both hold sensitive material -- `config.json` keeps each server's environment variables, the logs keep its output -- so Marina writes them at mode `0600` inside a `0700` directory, and deletes a server's log files when the server or its project is removed. `~/.config/marina/token` holds the control API token under the same modes.

Temporary jobs are intentionally absent from `config.json`. They exist only in the current Marina app session, appear separately as `temporaryServers` in `marina status --json`, and retain their terminal result for one hour so an agent can wait or inspect logs after a fast command completes.

```json
{
  "version": 1,
  "apiPort": 7737,
  "healthIntervalSeconds": 10,
  "maxRestartAttempts": 5,
  "logBufferLines": 5000,
  "logFileMaxMB": 10,
  "projects": [
    {
      "id": "prj_example",
      "name": "Example",
      "icon": "globe",
      "color": "#0A84FF",
      "root": "/absolute/path/to/project",
      "servers": [
        {
          "id": "srv_example",
          "name": "web",
          "command": "pnpm dev",
          "port": 5173,
          "directory": null,
          "env": {},
          "healthURL": null,
          "healthStatus": null,
          "autoRestart": true,
          "actions": [
            {
              "name": "clear-cache",
              "command": "trash .next/cache"
            }
          ]
        }
      ]
    }
  ]
}
```

`directory` may be absolute or relative to the project root. Marina provides `PORT`, `MARINA=1`, and `MARINA_SERVER` to child processes and configured actions. Actions run as supervised temporary jobs in the server's working directory without restarting or stopping the server. A bare port check connects to `localhost` over IPv4 or IPv6; `healthURL` may be a path such as `/api/health` or a complete URL.

## Local API

The control API listens only on `127.0.0.1:7737`. It can start processes, so it is deliberately unavailable to the network.

Loopback is not enough on its own, because the browser is also on loopback. The listener refuses any request carrying `Origin`, `Cookie`, or a `Sec-Fetch-*` header, accepts only a loopback `Host`, requires `application/json` for bodies, and never returns a CORS header. Requests are capped at 1 MB.

Every route that can read secrets or run a command also needs the token from `~/.config/marina/token`:

```bash
curl -H "Authorization: Bearer $(cat ~/.config/marina/token)" http://127.0.0.1:7737/config
```

`MARINA_TOKEN` overrides the file. The CLI reads it for you, so `marina` needs no setup. `/ping`, `/status`, `/start`, `/stop`, and `/restart` stay reachable without the token so the sandboxed App Store companion, which cannot read the file, keeps working; none of them can read an environment or a log. Routes marked below with a lock need the token.

| Method | Route | Purpose |
| --- | --- | --- |
| `GET` | `/ping` | Version and availability |
| `GET` | `/status` | Projects and live server state |
| `GET` | `/config` | Current configuration 🔐 |
| `GET` | `/logs?server=web&tail=200` | Recent server output 🔐 |
| `GET` | `/temporary/status?id=tmp_1234` | Temporary job state, deadline and exit code 🔐 |
| `GET` | `/ports?port=5173` | Process occupying a port 🔐 |
| `POST` | `/start`, `/stop`, `/restart` | Act on a server or project |
| `POST` | `/temporary/run` | Start a supervised background job outside any project 🔐 |
| `POST` | `/actions/run` | Run a configured server action without restarting it 🔐 |
| `POST` | `/memory-limit` | Configure the global default or a project memory guard 🔐 |
| `POST` | `/projects/add`, `/projects/remove` | Mutate projects 🔐 |
| `POST` | `/servers/add`, `/servers/update`, `/servers/remove` | Mutate servers 🔐 |
| `POST` | `/servers/take-over` | Move an external listener under Marina 🔐 |
| `POST` | `/ports/kill` | Send SIGTERM to a port occupant 🔐 |
| `POST` | `/open`, `/quit` | Control the app 🔐 |

Responses are JSON envelopes with `ok`, `data`, and `error` fields. The CLI is the supported agent-facing interface and handles launching the app and encoding requests.

## Agent skill

The distributable skill is in [`skills/marina`](skills/marina). The installer copies it to the canonical personal root at `~/.agents/skills/marina`, which is shared by Codex and Cursor and exposed to Claude through the standard `~/.claude/skills` compatibility link.

The source installer maintains a marker-delimited rule in `~/.agents/AGENTS.md`. The downloadable app's onboarding also installs it in `~/.claude/CLAUDE.md` so Claude receives the same global fallback. During project setup, the skill requires the same rule in the repository's root `AGENTS.md`; this makes the behavior portable to collaborators and other machines. Every write is idempotent and preserves existing instructions.
