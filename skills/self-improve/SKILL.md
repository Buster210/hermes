---
name: self-improve
description: "Critique a draft against a quality bar — correct, complete, and in Ritesh's terse taste — and revise it before sending. Bounded retries; applied ONLY to substantial outputs (autonomy results, plans, code, research), never to trivial or deliberately terse replies. Catches a weak first draft before he sees it."
version: 1.0.0
author: Hermes Assistant (SPEC-B Phase 5)
license: MIT
platforms: [linux, macos, windows]
environments: [cron, cli, gateway]
metadata:
  hermes:
    tags: [Self-Improve, Critique, Quality, Retry, Taste, Bounded, Review]
    related_skills: [autonomy-loop, taste-capture, skill-router]
---

# self-improve — critique and retry to a quality bar

Before you send a **substantial** output, grade your own draft and fix it if it
falls short — so Ritesh gets the second draft, not the first. This is the quality
cap on top of the other pillars. It rides the goals-loop judge (the runtime's
built-in retry-to-quality); there is no message interceptor.

## When to apply (selective — this matters for cost AND taste)

**Apply** to: `autonomy-loop` results, plans, code, research/analysis, anything
multi-step or that he'll act on.

**Skip** for: a one-line fact, a yes/no, a quick lookup, an intentionally terse
reply. Running the pass on these wastes tokens AND risks bloating answers he
wanted short. When in doubt about whether an output is "substantial", it usually
isn't — skip.

## The quality bar (all three, in order)

1. **Correct.** Right, complete for what was asked, verifiable, no hallucination.
   Claims are grounded; uncertainty is flagged, not hidden.
2. **In his taste.** TL;DR first, terse, `file:line` over vague refs, bullets over
   prose, no preamble/apology/fluff. Read the taste preferences in `USER.md` and
   match them. **Already terse + correct = it passes — do NOT pad it.** Over-long
   fails the bar exactly like wrong does.
3. **On-goal.** It actually answers the question / achieves the goal, not a
   tangent. Open items and assumptions are surfaced, not buried.

## The loop (bounded)

1. **Draft** the output.
2. **Critique** it against the three bars — one honest pass, name the specific
   gaps (not "could be better"). If it clears all three, **ship it now.**
3. **Revise** only the named gaps. A revision must not regress correctness or
   make a terse-good answer longer; if a revision is worse, keep the prior draft.
4. **Re-check** against the bar. Repeat **≤ 2 revisions** (3 drafts total, hard
   cap). If it still falls short at the cap, send the best draft **and say what's
   still weak** — don't loop, don't silently ship a known-weak result.

## Hard rules (never violate)

1. **Bounded.** ≤ 2 revisions, full stop. No infinite critique loop, no
   critique-of-the-critique. The runtime `goals.max_turns` is the outer backstop.
2. **Selective.** Substantial outputs only. Never burn a retry on a trivial or
   terse message.
3. **Respect his taste.** The bar enforces terseness — improving never means
   lengthening a good terse answer. Don't fight the style he set.
4. **No fabrication to "improve".** Better = more correct / clearer / better
   shaped. Never add unverified claims to look more complete.

## Done criteria
- Substantial output graded against correct + in-taste + on-goal. Real gaps fixed
  within ≤ 2 revisions; terse-good drafts shipped immediately unpadded. If still
  short at the cap, the weakness is stated, not hidden. Trivial/terse outputs
  skipped entirely.

## How this runs
- **Inside `autonomy-loop`** (step 5): run this pass before reporting a result.
- **As a goals-loop run:** the loop's judge provides the bounded retry-to-quality;
  this skill is the rubric it grades against. Composes with `taste-capture` (the
  taste half of the bar) and `skill-router` (which routes substantial work here).
