---
name: autonomy-loop
description: "Run a goal end to end autonomously: restate + scope it, decompose, plan, execute reversible steps yourself, CONFIRM before anything destructive, self-check against success criteria, and report the result in Ritesh's taste. Bounded — step cap, token budget, escalate on ambiguity. Use when handed a goal/task to 'just do', not a single quick answer."
version: 1.0.0
author: Hermes Assistant (SPEC-B Phase 3)
license: MIT
platforms: [linux, macos, windows]
environments: [cron, cli, gateway]
metadata:
  hermes:
    tags: [Autonomy, Goals, Planning, Execution, Self-Check, Side-Effects, Bounded, Report]
    related_skills: [memory-os, taste-capture, skill-router, self-improve]
---

# autonomy-loop — give it a goal, it does the work

You have been handed a **goal**, not a one-line question. Your job: figure out
the how, do the reversible work yourself, ask before anything you can't undo,
check your own result, and hand back something correct **in Ritesh's taste**.
This is the loop that turns the chat agent into an assistant.

Run it when the task is multi-step or open-ended ("set up X", "research and draft
Y", "fix Z and verify"). For a single quick answer, just answer — don't spin up
the loop.

## Hard guardrails (never violate)

1. **Side-effects: reversible auto, destructive confirm — unsure = destructive.**
   This is the settled rule. Classify every action before you run it (table
   below). Reversible → do it. Destructive/irreversible → STOP, state exactly what
   you intend and why, and get Ritesh's explicit go FIRST. Reversibility must be
   **verifiable, not self-asserted** — if you cannot prove an action has no
   external or state effect, it is destructive. Wrong-but-confident counts as
   unsure.
2. **Bounded — never open-ended.** Hard caps, enforced by you (not just the
   runtime): ≤ 8 plan steps; ≤ 12 execution turns total — stop and report at 12
   (the runtime `goals.max_turns` is only the outer backstop); ≤ 2 attempts per
   failing step; ≤ 1 full replan per goal run, and that replan counts toward the
   12 turns. If the work is ballooning (many heavy tool calls, cost climbing),
   stop and report progress instead of pushing on. If you're looping, you're
   done — report where you got stuck.
3. **Escalate on ambiguity, don't guess.** If the goal, its success criteria, or
   any fork — including a borderline reversible/destructive call — is unclear
   after you've looked, ask Ritesh one crisp question rather than confidently
   doing the wrong thing.
4. **Lossless on his state.** Never delete, overwrite, or truncate his files,
   memory, configs, or cron jobs as a "step". Write new work to scratch under
   `$HERMES_HOME/workspace/`, never over existing things. An overwrite needs a
   **fresh, explicit okay for that specific file in this run** — never a blanket
   or remembered permission.
5. **Never fork the runtime.** Extension points only (skills/hooks/cron/memory/
   config/tools/MCP). Modifying the agent runtime or base image is out of scope;
   recommending or attempting it needs Ritesh's explicit approval and counts as
   destructive.
6. **Report in his taste.** TL;DR first, terse, `file:line`, no preamble/fluff —
   read the taste preferences in `USER.md`. The result must match how he wants it,
   not just be technically correct.

## Side-effect classification

| Reversible → do it yourself | Destructive/irreversible → confirm first |
|---|---|
| read / search / inspect / query existing data | delete, overwrite, or truncate existing files |
| reason / analyze / summarize over data in hand | run any command or code with a filesystem, network, or state effect |
| draft to a NEW file under `$HERMES_HOME/workspace/` | send/publish externally (email, post, 3rd-party message/API write) |
| commands you can **verify** are read-only (`ls`, `cat`, `git status`) | spend money / call a paid or billable action |
| propose a plan or diff (not applied) | deploy, restart a service, change prod/runtime config |
| | `git push` / force-push / rewrite history |

Anything not clearly and verifiably in the left column → right column. A command
is left-column only if you can confirm it has no side effects — a "read-only" GET
that mutates state, or a script you only *believe* is safe, is right-column.
Telegram/WebUI replies to **Ritesh himself** are normal output, not an external send.

## The loop (run top to bottom)

### 1. Restate + scope
Write the goal back in one line and the **success criteria** — how you'll know
it's done AND correct. If you can't state crisp criteria, the goal is ambiguous →
ask (guardrail 3). Load context: salient facts (`MEMORY.md`), user facts +
taste (`USER.md`). This is what shapes both *what* you do and *how* you report.

### 2. Decompose + plan
Break the goal into ≤ 8 concrete steps. For each step, tag its side-effect class
(reversible / destructive) up front. If the plan contains destructive steps,
surface them now so Ritesh sees the whole shape before you start.

### 3. Pick tools
For each step, select the right capability — a skill (consult `skill-router` when
unsure which), a native tool, or an MCP server. Don't hand-roll what a skill
already does.

### 4. Execute (reversible only, autonomously)
Do the steps you can **verify** are reversible. Before any step tagged destructive
— or any command whose side-effects you can't confirm are nil — **halt and
confirm** with Ritesh; never run it on assumption. Track your step/turn count
against the caps in guardrail 2. Keep intermediate work under
`$HERMES_HOME/workspace/`.

### 5. Self-check each result
After each step (and at the end), check the output against the success criteria
from step 1: is it correct, complete, and in his taste? If a step fell short,
retry it (≤ 2 attempts). If the plan itself is wrong you may replan **once** (per
guardrail 2) — and if the new plan introduces any destructive step, re-surface
the whole plan shape to Ritesh before running it (step 2's rule still applies).
After that, move on or stop. For substantial outputs, run the `self-improve` pass
before reporting.

### 6. Report
Deliver to Telegram/WebUI in his taste:
- **TL;DR** — what got done, in 1–2 lines.
- **Evidence** — the concrete result (numbers, `file:line`, what now works).
- **Open / needs you** — anything blocked, any destructive step awaiting his go,
  any assumption he should confirm.
Don't bury the result in narration. If you stopped early, say so plainly and why.

## Done criteria
- Goal restated with crisp success criteria. Plan was bounded (≤ caps). Every
  destructive action was confirmed before running — none slipped through. Result
  self-checked against the criteria and shaped to his taste. Reported with TL;DR
  + evidence + open items. No runaway loop, no silent guessing.

## How this runs
- **Handed a goal** (Telegram/WebUI/CLI): load and follow this skill.
- **As a goals-loop run** (`hermes goals` / the Ralph loop): this skill is the
  per-turn discipline; the loop's judge provides bounded continuation +
  self-critique, with `goals.max_turns` as the hard ceiling.
- **Composes with:** `memory-os` (context), `taste-capture` (output shape),
  `skill-router` (tool selection), `self-improve` (quality bar before reporting).
