# Changelog

## Unreleased

- Compact island on screens without a notch (#22) — thanks @Kamasoutra
- Only web links (http/https) open from the notch; other kinds of links from Claude or integrations are ignored (#16) — thanks @Cris1670
- Hook socket limited to your own user account, with size and time limits; logs no longer keep commands, n8n data or full URLs, and stay under 1 MB (#16) — thanks @Cris1670 and @Vignesh-Thangamariappan
- The island always reopens after folding, and Settings opens below it, resizable — thanks @rouderz
- Choose the Claude model for the chat in Settings; the list comes from your Anthropic account, and Claude Sonnet 4.6 stays the default — thanks @rouderz
- Windows build artifacts are now downloadable from a manual CI run — thanks @MysJofR
- Any agent can talk to Mochi: tag a hook payload with `coucou_agent` (e.g. `nb-hook --agent my-agent`) and it gets its own pill in the island (#7, #9) — thanks @lacatu5
- Gemini CLI and Antigravity (agy) hook support on macOS: install from Settings and their sessions show up in the island — thanks @corefusiion
- GitHub, on macOS and Windows: the card follows the CI of your Claude Code session's branch, the reviews asked of you and your open pull requests; Mochi speaks up when a CI run finishes or a review comes in — thanks @JhoanG956
- Google Calendar, on macOS and Windows: a new pill with your next events and Join for the meeting that's on, and a reminder card when Google Calendar would ring; signs in with your own read-only OAuth client — thanks @JhoanG956
- Dragging a file onto the island and dropping it elsewhere (or pressing Escape) puts the island back the way it was, instead of leaving the drop zone open — thanks @JhoanG956
- Shell steps in the ticker drop the `cd <project> &&` prefix, so the command itself shows — thanks @JhoanG956
