# CC Inspector

A real-time monitoring dashboard for [Claude Code](https://claude.com/claude-code) instances. Captures every tool call, prompt, notification, and session lifecycle event via Claude Code's hook system and displays them in a live Phoenix LiveView dashboard.

## What It Does

CC Inspector listens for telemetry from all your Claude Code sessions by hooking into the [Claude Code hooks system](https://docs.anthropic.com/en/docs/claude-code/hooks). Every tool use (Bash, Edit, Write, Read, Grep, etc.), user prompt, notification, and session event is captured and stored in PostgreSQL, then streamed to the dashboard in real time via PubSub.

### Features

- **Real-time dashboard** - Watch tool calls arrive live as Claude works
- **Multi-session tracking** - Monitor all Claude Code instances simultaneously
- **Session detail views** - Drill into any session to see its full tool call and event history
- **Global tool calls view** - Browse all tool calls across sessions with status filters
- **Cost & token tracking** - Accumulated cost and token usage per session (when available)
- **Zero middleware** - Hooks POST directly from Claude Code to the Phoenix API

## Quick Start

### 1. Start the server

```bash
mix setup
mix phx.server
```

The dashboard is available at [localhost:4444](http://localhost:4444).

### 2. Install the hooks

Add the following to `~/.claude/settings.json`:

```json
"hooks": {
  "PreToolUse": [
    {
      "matcher": "",
      "hooks": [
        {
          "type": "command",
          "command": "curl -s -X POST http://localhost:4444/api/hooks/event -H 'Content-Type: application/json' -d @- >/dev/null 2>&1"
        }
      ]
    }
  ],
  "PostToolUse": [
    {
      "matcher": "",
      "hooks": [
        {
          "type": "command",
          "command": "curl -s -X POST http://localhost:4444/api/hooks/event -H 'Content-Type: application/json' -d @- >/dev/null 2>&1"
        }
      ]
    }
  ],
  "Notification": [
    {
      "matcher": "",
      "hooks": [
        {
          "type": "command",
          "command": "curl -s -X POST http://localhost:4444/api/hooks/event -H 'Content-Type: application/json' -d @- >/dev/null 2>&1"
        }
      ]
    }
  ],
  "UserPromptSubmit": [
    {
      "matcher": "",
      "hooks": [
        {
          "type": "command",
          "command": "curl -s -X POST http://localhost:4444/api/hooks/event -H 'Content-Type: application/json' -d @- >/dev/null 2>&1"
        }
      ]
    }
  ],
  "Stop": [
    {
      "matcher": "",
      "hooks": [
        {
          "type": "command",
          "command": "curl -s -X POST http://localhost:4444/api/hooks/event -H 'Content-Type: application/json' -d @- >/dev/null 2>&1"
        }
      ]
    }
  ],
  "SubagentStop": [
    {
      "matcher": "",
      "hooks": [
        {
          "type": "command",
          "command": "curl -s -X POST http://localhost:4444/api/hooks/event -H 'Content-Type: application/json' -d @- >/dev/null 2>&1"
        }
      ]
    }
  ],
  "PreCompact": [
    {
      "matcher": "",
      "hooks": [
        {
          "type": "command",
          "command": "curl -s -X POST http://localhost:4444/api/hooks/event -H 'Content-Type: application/json' -d @- >/dev/null 2>&1"
        }
      ]
    }
  ]
}
```

All hooks point to a single `/api/hooks/event` endpoint. The server parses the `hook_event_name` field to route each event.

### 3. Use Claude Code

Start any Claude Code session and the dashboard will begin showing live data.

## Architecture

```
Claude Code hooks (curl) --> POST /api/hooks/event --> HookController
                                                           |
                                                     Monitoring context
                                                           |
                                                        PostgreSQL
                                                           |
                                                    PubSub broadcast
                                                           |
                                                  LiveView dashboards
```

### How it works

1. **Hooks** - Claude Code fires hook events as JSON on stdin, which `curl` pipes via `@-` to the API
2. **API** - A single endpoint receives all events, parses `hook_event_name` to determine the type, persists to the database, and broadcasts via PubSub
3. **Dashboard** - LiveView pages subscribe to PubSub topics and update in real time as events arrive

### Pages

| Route | Description |
|-------|-------------|
| `/` | Dashboard with metric cards, tool usage breakdown, and live activity feed |
| `/sessions` | All sessions with active/stopped filter |
| `/sessions/:id` | Session detail with tabbed tool calls and events |
| `/tool-calls` | Global tool calls across all sessions with status filter |

### Database

Three tables store everything:

- **sessions** - Each Claude Code instance (session_id, cwd, status, started/stopped, cost, tokens)
- **tool_calls** - Every tool invocation (tool_name, input, output, status, duration)
- **events** - Notifications, user prompts, stops, subagent stops, compaction events

### Hook events captured

| Event | What it captures |
|-------|-----------------|
| `PreToolUse` | Tool name and input before execution |
| `PostToolUse` | Tool result, duration, success/error status |
| `UserPromptSubmit` | User's prompt text |
| `Notification` | Claude Code notifications |
| `Stop` | Session end |
| `SubagentStop` | Sub-agent completion |
| `PreCompact` | Context window compaction |

## Development

```bash
mix setup          # Install deps and create database
mix phx.server     # Start the server on port 4444
mix test           # Run tests
mix precommit      # Format, compile, and run tests
```
