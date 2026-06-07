---
name: memory-os
description: "Self-managing tiered memory consolidation. Distills recent sessions into durable long-term memory and keeps MEMORY.md + USER.md current within their caps. Runs on a schedule (cron), additive and lossless."
version: 1.0.0
author: Hermes Assistant (SPEC-B Phase 1)
license: MIT
platforms: [linux, macos, windows]
environments: [cron, cli, gateway]
metadata:
  hermes:
    tags: [Memory, Consolidation, Self-Management, Cron, Tiered-Memory, USER.md, MEMORY.md]
    related_skills: []
---

# memory-os — self-managing tiered memory consolidation

You are running the **memory consolidation pass**. Your job: turn raw recent
conversation into durable, deduped, prompt-ready memory — **without ever losing
or corrupting existing memory**. This is the bedrock the assistant's taste,
autonomy, and self-improvement build on.

## Memory tiers (what lives where)

- **Working / hot (prompt-injected every session):**
  - `state.db` → `messages` table — raw recent conversation (runtime-owned).
  - `memories/MEMORY.md` — agent's salient notes/env facts. **Hard cap ~2200 chars.**
  - `memories/USER.md` — facts about the user (Ritesh): prefs, style, recurring
    corrections. **Hard cap ~1375 chars.**
  - Entries in both files are separated by a `§` line (delimiter `\n§\n`).
- **Long-term / durable (NOT prompt-injected, uncapped, the real archive):**
  - `memories/longterm/MEMORY-archive.md` — full consolidated agent history.
  - `memories/longterm/USER-archive.md` — full consolidated user-fact history.
  - `memories/longterm/.watermark` — unix timestamp of the last consolidated message.

The capped files are the **distilled, salient subset** that fits the prompt; the
archive holds everything so nothing is lost when the caps force pruning.

## Hard rules (never violate)

1. **Additive + lossless.** Never delete a durable fact. Pruning the capped files
   is allowed ONLY after the same content is preserved in the archive.
2. **Back up before any write** (see step 1). The rolling backup is last-known-good.
3. **No secrets / no PII.** Never write API keys, tokens, passwords, full emails,
   phone numbers, or credentials into any memory file. If a fact references one,
   record the fact, not the secret.
4. **No hallucinated facts.** Only record what the conversation actually shows.
   Tag any inference with a confidence + provenance note, e.g.
   `(confidence: medium — inferred from 2026-06-07 session)`.
5. **Bounded.** One pass, no loops. Read recent messages only (since the watermark).
   Do not re-summarize the whole history every run.
6. **Respect the caps.** After updating, MEMORY.md ≤ 2200 chars and USER.md ≤ 1375
   chars. Use the `memory` tool (it enforces caps + drift-detection) for these two
   files when available; fall back to careful file edits preserving the `§` format.

## Procedure (run top to bottom, once)

### 1. Back up current memory (last-known-good)
Run this exactly (it overwrites the single rolling backup — bounded, not unbounded):

```bash
mkdir -p "$HERMES_HOME/memories/longterm" "$HERMES_HOME/memories/.backups"
for f in MEMORY.md USER.md; do
  [ -f "$HERMES_HOME/memories/$f" ] && cp -a "$HERMES_HOME/memories/$f" "$HERMES_HOME/memories/.backups/$f.bak" || true
done
```

### 2. Pull new conversation since the last pass
Use python (sqlite3 is stdlib — always present). This reads only messages newer
than the watermark, so the pass stays cheap:

```bash
python3 - <<'PY'
import os, sqlite3, pathlib
home = pathlib.Path(os.environ["HERMES_HOME"])
db = home / "state.db"
wm = home / "memories" / "longterm" / ".watermark"
since = float(wm.read_text().strip()) if wm.exists() else 0.0
if not db.exists():
    print("NO_DB"); raise SystemExit
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
rows = con.execute(
    "SELECT timestamp, role, content FROM messages "
    "WHERE timestamp > ? AND role IN ('user','assistant') AND content IS NOT NULL "
    "ORDER BY timestamp ASC LIMIT 400",
    (since,),
).fetchall()
if not rows:
    print("NO_NEW_MESSAGES"); raise SystemExit
maxts = max(r[0] for r in rows)
print(f"MAXTS={maxts}")
print(f"COUNT={len(rows)}")
for ts, role, content in rows:
    print(f"--- {role} @ {ts} ---")
    print((content or "")[:2000])
PY
```

If output is `NO_DB` or `NO_NEW_MESSAGES`, **stop here** — there is nothing to
consolidate. Exit quietly (no delivery).

### 3. Distill
From the pulled messages extract, separately:
- **User facts** (→ USER.md / USER-archive.md): durable preferences, working
  style, recurring corrections, standing decisions, domains he cares about.
- **Agent/world facts** (→ MEMORY.md / MEMORY-archive.md): environment facts,
  project state, salient events, things worth remembering next session.
Drop chit-chat. Merge each new fact with what already exists (dedupe — refine an
existing entry rather than appending a near-duplicate).

### 4. Append to the long-term archive (durable, uncapped)
Append the newly distilled facts (with date + provenance) to
`memories/longterm/MEMORY-archive.md` and `memories/longterm/USER-archive.md`.
**Append only — never rewrite or truncate the archive.**

### 5. Refresh the capped hot files
Update `memories/MEMORY.md` and `memories/USER.md` to hold the **most salient,
deduped** subset, within the caps. Prefer the `memory` tool:
- `memory` add / replace / remove with `target: "memory"` or `target: "user"`.
- It enforces the char cap and detects external drift; honor its errors.
If a cap is hit, keep the highest-value entries in the hot file (the rest already
live in the archive). Entries stay `§`-separated. Tag inferred facts with
confidence + provenance.

### 6. Advance the watermark
Only after steps 4–5 succeed, write the `MAXTS` value printed in step 2 into the
watermark file so the next pass starts where this one ended:

```bash
echo -n "<MAXTS from step 2>" > "$HERMES_HOME/memories/longterm/.watermark"
```

## Done criteria
- Backup written. Archive grew (or NO_NEW_MESSAGES). Hot files within caps and
  reflecting the latest salient facts. Watermark advanced. No secrets stored.
  Existing memory intact. One pass, no loops.

## Recall (how this memory reaches the agent)
The runtime injects `MEMORY.md` + `USER.md` into the system prompt at session
start (frozen snapshot per session). So consolidation done now is referenced by
the agent on its next session automatically — no extra wiring needed. The
long-term archive is the durable backstop, read on demand.
