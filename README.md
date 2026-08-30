# CC Inspector

A local Phoenix LiveView app for browsing Claude Code, Codex, and OpenCode session history.

It reads the transcripts those tools already keep on your machine and renders them as one navigable, live-updating UI. There are no hooks to install and no remote usage APIs or credential files involved.

![CC Inspector sessions index](docs/sessions.png)

## What you get

- **Usage dashboard** — 30-day input / cached / output / total tokens, each with a 7-day figure, a week-over-week trend, and a sparkline, above daily stacked-bar charts broken down by token type and by provider.
- **Sessions index** — local sessions grouped by project and sorted by recent activity, with provider filters, titles, prompts, models, duration, turn count, and token usage.
- **Session detail** — the full conversation rendered turn-by-turn: user prompts, assistant text, thinking blocks (with an "encrypted" pill for redacted thinking from newer models), and paired tool calls + results with pretty-printed input and output. Long assistant blocks collapse so you can scan a session quickly.
- **Filter** — narrow the list by provider, project path, prompt text, title, branch, or session id.
- **Live updates** — filesystem and database watchers pick up active Claude Code, Codex, and OpenCode sessions.

## Quick start

You'll need Elixir 1.15+ and Erlang/OTP installed.

```bash
git clone https://github.com/matthusby/cc_inspector.git
cd cc_inspector
mix setup
mix phx.server
```

Then open <http://localhost:4444>.

## Configuration

By default the app reads:

- Claude Code: `~/.claude/projects`
- Codex: `~/.codex/sessions` and `~/.codex/archived_sessions`
- OpenCode: `~/.local/share/opencode/opencode.db`, read directly with the `sqlite3` executable (supports both OpenCode 1 and OpenCode 2 schemas)

Override those locations with environment variables:

```bash
CLAUDE_PROJECTS_DIR=/path/to/claude/projects
CODEX_HOME=/path/to/.codex
OPENCODE_DATA_DIR=/path/to/opencode/data
OPENCODE_SQLITE=/path/to/sqlite3
```

Or configure the enabled providers directly:

```elixir
# config/dev.exs
config :cc_inspector, session_providers: [:claude, :codex, :opencode]
```

The app only reads session data. It does not read provider credential files or write to agent history.

## Development

```bash
mix setup       # fetch deps, install + build assets
mix phx.server  # http://localhost:4444
mix test        # run the test suite
mix precommit   # compile --warnings-as-errors, deps.unlock --unused, format, test
```

The test suite uses sandboxed directories and synthetic Claude, Codex, and OpenCode records, so it does not touch your real session history.
