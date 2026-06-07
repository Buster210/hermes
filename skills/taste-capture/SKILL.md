---
name: taste-capture
description: "Learn and apply Ritesh's taste. Distills correction/redo/rejection signals into a confidence-gated preferences profile (durable ledger) and refreshes a marked taste block in USER.md so every output is shaped to his style. Runs on a schedule (cron), additive and lossless."
version: 1.0.0
author: Hermes Assistant (SPEC-B Phase 2)
license: MIT
platforms: [linux, macos, windows]
environments: [cron, cli, gateway]
metadata:
  hermes:
    tags: [Taste, Preferences, Style, Self-Management, Cron, USER.md, Corrections, Feedback]
    related_skills: [memory-os]
---

# taste-capture — learn and apply the user's taste

You are running the **taste consolidation pass**. Your job: turn raw correction
signals into a small, confidence-gated **preferences profile** that shapes how
the agent writes for Ritesh — terse, file:line, no fluff, in his voice — **without
ever overwriting memory or erasing personality**. This is preference-*shaping*,
not personality-replacement.

## What lives where

- **Signal queue (input):** `memories/longterm/TASTE-signals.md` — raw
  correction/redo/rejection candidates appended by the `taste-capture` hook.
  Cheap, noisy, type-agnostic. Cleared after this pass consumes it.
- **Taste ledger (durable, uncapped):** `memories/longterm/TASTE-ledger.md` —
  the real preferences profile. Every learned preference with date, provenance,
  and a confidence note. Append/refine only — never truncate.
- **USER.md taste block (prompt-injected, capped):** the top preferences,
  distilled, between the markers `<!-- TASTE:START -->` and `<!-- TASTE:END -->`.
  This block is the only part of `USER.md` you may edit; everything outside the
  markers is owned by `memory-os` (user facts) — **preserve it byte-for-byte.**

The ledger is the source of truth; the USER.md block is a regenerable projection.
If anything ever clobbers the block, this pass restores it from the ledger.

## Hard rules (never violate)

1. **Lossless on memory.** Edit only the marked taste block in `USER.md`. Never
   touch `MEMORY.md`, the memory-os archives, or any `USER.md` content outside
   the markers. The ledger is append/refine only.
2. **Back up before any write** (step 1).
3. **Confidence-gate.** Only promote a preference that is **explicitly stated**
   or **seen ≥2 times**. One-off reactions stay in the ledger at low confidence;
   they do not enter `USER.md`. Tag every entry: `(confidence: high|medium|low —
   <provenance>, <date>)`.
4. **No secrets / no PII.** Never write keys, tokens, passwords, full emails,
   phone numbers. Record the preference, never the secret.
5. **Shape, don't erase.** Preferences refine output style; they never override
   `SOUL.md` identity or contradict standing user facts. No sycophancy drift.
6. **Bounded.** One pass, no loops. Respect the `USER.md` ~1375-char cap.

## Procedure (run top to bottom, once)

### 1. Back up
```bash
mkdir -p "$HERMES_HOME/memories/longterm" "$HERMES_HOME/memories/.backups"
for f in USER.md; do
  [ -f "$HERMES_HOME/memories/$f" ] && cp -a "$HERMES_HOME/memories/$f" "$HERMES_HOME/memories/.backups/$f.bak" || true
done
[ -f "$HERMES_HOME/memories/longterm/TASTE-ledger.md" ] && cp -a "$HERMES_HOME/memories/longterm/TASTE-ledger.md" "$HERMES_HOME/memories/.backups/TASTE-ledger.md.bak" || true
```

### 2. Read the signal queue (+ fallback)
```bash
cat "$HERMES_HOME/memories/longterm/TASTE-signals.md" 2>/dev/null || echo "NO_SIGNALS"
```
If the queue is empty/`NO_SIGNALS`, **fall back** to recent raw conversation so
taste is still learned even if the hook never fired. Read only messages newer
than the watermark (cheap), reusing the memory-os pattern:
```bash
python3 - <<'PY'
import os, sqlite3, pathlib
home = pathlib.Path(os.environ["HERMES_HOME"])
db = home / "state.db"
wm = home / "memories" / "longterm" / ".taste-watermark"
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
print(f"MAXTS={max(r[0] for r in rows)}")
for ts, role, content in rows:
    print(f"--- {role} @ {ts} ---")
    print((content or "")[:1500])
PY
```
If both the queue and fallback are empty, **stop here** — nothing to learn. Exit
quietly (no delivery).

### 3. Distill preferences
From the signals (and fallback messages) extract durable **preferences**, not
events. Each is a short imperative rule about how Ritesh wants outputs:
- **Format/length** — e.g. "prefers ≤3-line answers; bullets over prose".
- **Style/voice** — e.g. "no preamble, no apologies, file:line over vague refs".
- **Domain/standing** — e.g. "wants tradeoffs surfaced before a recommendation".
- **Recurring corrections** — what he repeatedly redoes/rejects.
Drop one-offs and noise. Merge with existing ledger entries (refine a near-match,
do not append a duplicate). Confidence-gate per rule 3.

### 4. Append to the durable ledger
Append newly learned / refined preferences to
`memories/longterm/TASTE-ledger.md` with date + provenance + confidence. Example:
```
- Answers must lead with the TL;DR, ≤3 lines unless asked. (confidence: high — stated + 4 corrections, 2026-06-07)
- Prefers `file:line` references over "somewhere in X". (confidence: high — 3 corrections, 2026-06-07)
```
**Append/refine only — never rewrite or truncate the ledger.**

### 5. Refresh the USER.md taste block
Project the **top, highest-confidence** preferences into `USER.md` between the
markers. Create the block if absent; replace only what is between the markers;
keep all other `USER.md` content exactly as-is. Size the block to the headroom:
keep total `USER.md` ≤ ~1375 chars (if tight, keep the highest-value rules — the
rest stay in the ledger). Use the `memory` tool with `target: "user"` when it
can target the marked region; otherwise edit the file carefully.
```
<!-- TASTE:START -->
## Preferences (taste — auto-learned, confidence-gated)
- <top preference 1>
- <top preference 2>
- <top preference 3>
<!-- TASTE:END -->
```

### 6. Clear the queue + advance the watermark
Only after steps 4–5 succeed, empty the consumed signal queue and (if you used
the fallback) advance the watermark so the next pass starts fresh:
```bash
: > "$HERMES_HOME/memories/longterm/TASTE-signals.md"
# if fallback was used, write the MAXTS from step 2:
# echo -n "<MAXTS>" > "$HERMES_HOME/memories/longterm/.taste-watermark"
```

## Done criteria
- Backup written. Ledger grew or refined (or nothing to learn). USER.md taste
  block reflects the top preferences, within the cap, with all non-taste content
  intact. Queue cleared. No secrets stored. One pass, no loops.

## How taste reaches the agent
The runtime injects `USER.md` into the system prompt at session start (frozen
snapshot per session). The taste block rides along, so the preferences learned
now shape the agent's next session automatically — no extra wiring. Composes
with `self-improve` (the quality bar reads these preferences) and `autonomy-loop`
(reports in this style).
