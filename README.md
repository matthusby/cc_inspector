# CC Inspector

A local Phoenix LiveView app for browsing your [Claude Code](https://claude.com/claude-code) session history.

It reads the JSONL transcript files Claude Code already writes to `~/.claude/projects/` and renders them as a navigable, live-updating UI. There's no database, no hooks to install, and nothing to configure — point it at your machine and start it.

## What it shows

- **Sessions index (`/`)** — every session on disk, grouped by project, sorted by most recent activity. Each row shows the AI-generated title (when present), first user prompt, branch, duration, turn count, and token usage (input / cached / output).
- **Session detail (`/sessions/:id`)** — the full conversation rendered turn-by-turn: user prompts, assistant text, thinking blocks (with an "encrypted" pill for redacted thinking from newer models), and paired tool calls + results with pretty-printed input and output.
- **Live updates** — a file-system watcher invalidates a small ETS cache and broadcasts over Phoenix PubSub when transcripts change, so open pages re-render as Claude works.

## Quick start

```bash
mix setup
mix phx.server
```

Then open <http://localhost:4444>.

By default the app reads `~/.claude/projects`. Override it in config if Claude Code writes elsewhere:

```elixir
# config/dev.exs
config :cc_inspector, claude_projects_dir: "/path/to/projects"
```

## How it works

```
~/.claude/projects/<slug>/<session-id>.jsonl
                │
                │  FileSystem watcher
                ▼
        Sessions.Cache (ETS, mtime/size invalidated)
                │
                │  Parser → Summary / Turns
                ▼
        Phoenix PubSub (sessions, session:<id>)
                │
                ▼
            LiveView
```

- **Parser** (`lib/cc_inspector/sessions/parser.ex`) — streams a JSONL file into typed `Event` structs, classifying each record (`user`, `assistant`, `system`, `ai-title`, `attachment`, `permission-mode`, `file-history-snapshot`, etc.).
- **Summary** (`lib/cc_inspector/sessions/summary.ex`) — folds events into the row shown on the index: timestamps, turn counts, deduped token usage, first prompt, AI title.
- **Turns** (`lib/cc_inspector/sessions/turns.ex`) — pairs `tool_use` blocks with their matching `tool_result` so the detail view can render them together.
- **Cache** (`lib/cc_inspector/sessions/cache.ex`) — ETS-backed; entries are invalidated by mtime + size, so re-reads only happen when a file actually changes.
- **Watcher** (`lib/cc_inspector/sessions/watcher.ex`) — listens for filesystem events under the projects dir and broadcasts `:session_created` / `:session_updated` / `:session_removed`. Sub-agent transcripts (under `<id>/subagents/`) are intentionally not surfaced as top-level sessions.

## Development

```bash
mix setup       # fetch deps, install + build assets
mix phx.server  # http://localhost:4444
mix test        # run the test suite
mix precommit   # compile --warnings-as-errors, deps.unlock --unused, format, test
```

The test suite uses a sandboxed projects directory (see `test/support/fixtures.ex`) and writes synthetic JSONL transcripts, so it doesn't touch your real `~/.claude` directory.
