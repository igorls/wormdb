# Agent Execution System (PM-Led)

This repository uses a **PM + subagent** workflow:

- **PM (Copilot)** defines work packages, acceptance criteria, and constraints.
- **Execution agents** implement one package at a time.
- **PM** reviews output, decides pass/fail, creates follow-up packages, and continues until objective is complete.

## Source of Truth

- Backlog and priorities: [BACKLOG.md](./BACKLOG.md)
- Work package specs: [work-packages/](./work-packages/)
- Review records: [reviews/](./reviews/)
- Review checklist: [REVIEW_TEMPLATE.md](./REVIEW_TEMPLATE.md)

## Lifecycle

1. Pick highest-priority `Ready` item from `BACKLOG.md`.
2. Execute exactly one work package.
3. Run required validation commands in the package.
4. Submit change summary + test evidence.
5. PM writes a review note under `reviews/` with outcome:
   - `Approved`
   - `Changes Requested`
   - `Blocked`
6. PM updates backlog status and either:
   - opens next package, or
   - opens follow-up package for discovered issues.

## Rules for Execution Agents

- Stay in package scope; no unrelated refactors.
- Follow constraints and acceptance criteria exactly.
- If blocked, stop and report blocker with evidence.
- Do not mark complete without passing listed validation.

## Status Labels

- `Draft` – package exists but not ready.
- `Ready` – can be executed now.
- `In Progress` – currently assigned.
- `Review` – waiting PM review.
- `Done` – approved and merged.
- `Blocked` – cannot proceed until dependency is resolved.
