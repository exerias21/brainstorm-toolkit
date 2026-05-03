# Question typology — 9 buckets

Pick 3–5 buckets per run, not all 9. Justify the pick to the user.

## 1. Scope
**Intent**: draw the sharp line between in and out.
- What's explicitly out of scope?
- If we had to ship half of this, which half?
- Is there a related thing nearby that you'd be tempted to bundle in?
**Saturated when**: the user has named at least 2 explicit non-goals.

## 2. Success
**Intent**: define observable signals so we can tell after the fact.
- How will we know this worked?
- What metric or behavior would change if it succeeded?
- What's the difference between "shipped" and "successful"?
**Saturated when**: at least one observable signal is named (a metric, a behavior, a user reaction).

## 3. Failure
**Intent**: surface blast radius before building.
- What does broken look like for this feature?
- Who notices first? How fast?
- What's the rollback cost if we ship and it breaks?
**Saturated when**: failure mode + detection + rollback are all named.

## 4. Audience
**Intent**: pin down who, how often, in what state.
- Who is the primary user of this?
- How often will they touch it? Daily, weekly, once?
- What state are they in when they hit it (focused, panicked, exploring)?
**Saturated when**: a primary user persona + frequency + context are all named.

## 5. Priors
**Intent**: avoid rebuilding something that was already tried.
- Has anything like this been attempted before in this codebase?
- What was rejected and why?
- Is there an external project that solved this — what did they do?
**Saturated when**: at least one prior attempt or rejection reason is surfaced (or the user confirms there are none).

## 6. Trade-offs
**Intent**: name the axis where we'll accept worse to win elsewhere.
- Where will we accept worse on X to win on Y?
- Speed vs. correctness — which dominates here?
- Generality vs. fit — are we building this for one case or many?
**Saturated when**: at least one explicit trade-off is named in the form "we'll accept worse on X to win on Y."

## 7. Constraints
**Intent**: surface non-negotiables early.
- What's the time budget? Hard deadline?
- What dependencies must we honor (libraries, services, team capacity)?
- Are there compliance, security, or political constraints?
**Saturated when**: at least one binding constraint is named OR the user confirms there are none.

## 8. Reversibility
**Intent**: classify the door.
- Is this a one-way or two-way door?
- If we ship and it's wrong, how hard is undo?
- What part of this commits us to a path we can't easily back out of?
**Saturated when**: the reversibility class is explicitly named.

## 9. Resemblance
**Intent**: borrow from what already worked.
- What other feature does this remind you of?
- What worked there? What didn't?
- Is there a pattern in this codebase we should follow rather than invent?
**Saturated when**: at least one analog (in this codebase or out) is named.

## How to format the batch

Pick 3–5 buckets. Ask one question per bucket (don't stack 3 questions inside one bucket — that's noise). Format:

> **Quick clarifications — 4 questions** (Scope, Failure, Trade-offs, Reversibility):
>
> 1. *Scope*: <question>
> 2. *Failure*: <question>
> 3. *Trade-offs*: <question>
> 4. *Reversibility*: <question>

After the user answers, self-score: "what do I still not know that would change the design?" If the answer is "very little," proceed to Pass 3. If "a lot," ask another batch (max 3 batches total).
