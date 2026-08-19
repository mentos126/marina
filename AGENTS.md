# Repository instructions

## Development servers

- Always use Marina (`marina ...`) to start, stop, restart, inspect, or keep local development servers running.
- Start with `marina status`. Use `marina status --details` only for the full inventory and metrics, and `--json` only for machine-readable fields. Reuse a healthy managed server; if an in-scope server is running outside Marina, register it and use `marina take-over <project/server> --json`.
- For long-lived or reusable work, create a project and server.
- For builds, tests, code generation, previews, demos, and other bounded one-off work, run `job_id="$(marina temp '<command>' --path <folder> --timeout 30m)"`, then `marina wait "$job_id"`. `temp` returns immediately with an ID; `wait` prints captured logs and exits with the command's real code. A timeout kills the whole process group and exits with code `124`.
- Never launch persistent development servers directly, in the background, or through another supervisor.
- Server output can contain secrets: a dev server that echoes a database URL or an API key puts it in `marina logs`. Quote the lines you need, not whole log dumps, and never copy log content into a commit message, an issue, or a pull request.
