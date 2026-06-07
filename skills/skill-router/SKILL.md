---
name: skill-router
description: "Pick the right skill(s) for a task automatically. Match task intent against the installed skills and route to the best fit — compose them when needed, ask when genuinely ambiguous, never bypass safety gates. Consult at the start of any non-trivial task before doing it the manual way."
version: 1.0.0
author: Hermes Assistant (SPEC-B Phase 4)
license: MIT
platforms: [linux, macos, windows]
environments: [cron, cli, gateway]
metadata:
  hermes:
    tags: [Routing, Skills, Dispatch, Intent-Matching, Composition, Autonomy]
    related_skills: [autonomy-loop, memory-os, taste-capture, self-improve]
---

# skill-router — route a task to the right skill

Before you handle a non-trivial task the manual way, **check whether an installed
skill already does it** and route to it. The runtime injects the skill index
(every skill's name + description) into your prompt — this skill is the discipline
for using that index well, so the right capability fires without Ritesh having to
name it.

Skip routing for a trivial direct answer (a fact, a one-liner) — just answer.
Route when the task is multi-step, specialized, or matches a skill's purpose.

## Routing procedure

1. **Read intent.** What is the task actually trying to achieve? Strip the
   phrasing down to the goal.
2. **Match against the index.** Compare that intent to each installed skill's
   `description`. Score the fit. Use the quick map below for the assistant skills;
   for any other installed skill, match on its description.
3. **Decide:**
   - **One clear winner** → load its body (`skill_view`) and follow it.
   - **Several fit** → compose them in the right order (e.g. route through
     `autonomy-loop`, which itself calls this router per step). Don't run
     overlapping skills that fight each other.
   - **None clearly fit** → don't force a skill; handle the task directly.
   - **Genuinely ambiguous** between very different skills → ask Ritesh one crisp
     question; don't guess.
4. **Hand off, keep the gates.** Routing selects *what* runs; it never relaxes
   *how*. Every safety gate of the target skill still applies — routing to
   `autonomy-loop` does NOT skip its destructive-confirm gate.

## Quick map (intent → skill)

| If the task is about… | Route to |
|---|---|
| running a goal end-to-end: plan, execute, self-check, report | `autonomy-loop` |
| remembering/consolidating conversations, updating MEMORY.md/USER.md | `memory-os` |
| learning/applying Ritesh's style, corrections, preferences | `taste-capture` |
| checking/improving a draft against a quality bar before sending | `self-improve` |
| "which skill should handle this?" | (this skill — don't recurse) |
| anything else with a matching installed skill | that skill, by its description |

## Rules

- **Ask, don't mis-route.** A confident wrong route is worse than asking. Default
  to ask when two plausible routes diverge in side-effects or outcome.
- **Never bypass safety.** Routing must not be a path around a confirm-gate,
  budget cap, or lossless rule. The target skill's guardrails are binding.
- **No meta-loops.** Don't route the router, and don't bounce a task between
  skills — one routing decision per task (re-route only if the first was wrong).
- **Compose, don't duplicate.** If `autonomy-loop` is already running, let it own
  per-step tool selection (it consults this map); don't double-route.

## How this runs (and its ceiling)
This is the **confirmed-primitive** router: the runtime injects the skill index
and you select from it — reliable today, no runtime change. The higher-ceiling
version (an `agent:start` hook that programmatically pre-injects the matched
skill body) needs a prompt-injection API not confirmed in the pinned image; it's
flagged in `ASSISTANT-ROADMAP.md` (Missing primitives) for Ritesh, per the
settled "accept lower-ceiling, escalate" decision. Composes with `autonomy-loop`
(tool selection) and every other installed skill.
