---
name: Always start capture server for RE sessions
description: When /reverse-engineer skill is invoked, always start the capture web UI first — don't analyze old captures unless explicitly asked
type: feedback
---

When the /reverse-engineer skill is triggered, always start the capture server (localhost:8642) immediately so the user can begin capturing. Don't look at or analyze old captures unless the user explicitly asks to review them.

**Why:** The user uses the skill as a shortcut to launch the capture workflow, not for retrospective analysis.
**How to apply:** First action in any RE session = `python capture_server.py` in background, then tell the user it's ready.
