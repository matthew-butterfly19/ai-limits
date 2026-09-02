# Security model

AILimits reads local log files and asks two vendor APIs how much of your rate limit
you have used. That is the whole of it. Concretely:

**What it reads**

- `~/.claude/projects/**/*.jsonl` — Claude Code session transcripts. Only token counters,
  timestamps, model names, session ids and working directories are parsed. Message content
  is never read into memory beyond the substring scan used to skip irrelevant lines.
- `~/.codex/sessions/**/*.jsonl` and `~/.codex/archived_sessions/**` — the same for Codex,
  plus the rate-limit snapshots Codex records in its own logs.
- The `Claude Code-credentials` Keychain item, at the moment of each refresh, to obtain the
  OAuth access token Claude Code already stores there.

**What it sends**

- `GET https://api.anthropic.com/api/oauth/usage` with your Claude Code token.
- A local JSON-RPC call to `codex app-server`, which asks OpenAI for your Codex limits.
- `GET https://openrouter.ai/api/v1/keys` and `/activity`, only if you configured a
  management key — that is what turns dsh's token counts into what they actually cost.

Nothing else leaves the machine. No telemetry, no analytics, no crash reporting.

**What it stores**

- `~/Library/Application Support/AILimits/stats.db` — aggregated token counters, session
  titles and limit samples. No message content, no credentials.
- `~/Library/Application Support/AILimits/openrouter-key`, mode `0600` — your OpenRouter
  management key, if you configured one. It lives in a file rather than the Keychain because
  a Keychain item's access list is pinned to one binary: every local rebuild counted as a
  different app, so macOS asked for the login keychain password after every install and
  "Always Allow" did not survive it. A file readable only by your account ends that; it is
  never committed, never logged, and never leaves the machine except as an `Authorization`
  header to openrouter.ai.
- The Keychain token is held in memory for the duration of one request and is never written
  to disk, logged, or included in error messages.

**Reporting a problem**

Open an issue. If the problem is a credential-handling flaw, say so in the title and skip the
proof-of-concept details in the public description.
