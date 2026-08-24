# FARBERMAKERS Development Rules

## Purpose

This document defines the mandatory development workflow for the FARBERMAKERS project.

Every future task must follow these rules unless I explicitly override them.

---

# 1. Backup Policy (MANDATORY)

Before modifying ANY project file:

- Create a backup first.
- Never modify files before the backup exists.
- Create the folder if necessary:

/BKP/

Inside it create a timestamp folder:

YYYY-MM-DD HH-MM-SS

Example:

BKP/
└── 2026-07-13 15-42-18/

Copy every file that will be modified while preserving the folder structure.

Never overwrite previous backups.

If the backup cannot be created:

STOP.

Do not modify any project file.

Report the problem.

---

# 2. Minimal Changes

Modify only the files necessary.

Do not touch unrelated files.

Avoid formatting-only edits unless requested.

Keep diffs as small as possible.

---

# 3. Preserve Existing Behavior

Never change existing behavior unless explicitly requested.

Never introduce breaking changes.

Never remove existing features.

---

# 4. Refactoring Policy

Small refactors are allowed.

Large refactors require approval first.

Before a major architectural change:

- Explain why.
- Explain benefits.
- Explain risks.
- Wait for approval.

---

# 5. Dead Code

Never remove code simply because it appears unused.

Verify first.

If uncertain, ask.

---

# 6. Bug Handling

If unrelated bugs are discovered:

Do NOT fix them automatically.

List them separately.

Only fix bugs that belong to the requested task unless instructed otherwise.

---

# 7. Coding Style

Maintain the existing coding style.

Use meaningful names.

Prefer readability over clever code.

Avoid unnecessary abstractions.

Keep functions focused.

---

# 8. Testing

After every modification:

- Verify syntax.
- Verify there are no runtime errors.
- Verify no regressions were introduced.
- Verify affected functionality still works.

---

# 9. Final Report

Every completed task must end with:

## Backup

Location:

Files backed up:

## Modified Files

List every modified file.

## Validation

- Syntax: PASS / FAIL
- Runtime: PASS / FAIL
- Regression Check: PASS / FAIL

## Summary

Short explanation of what changed.

---

# 10. Safety

If a request could accidentally damage the project:

Stop.

Explain the risk.

Ask for confirmation.

---

# 11. Working Philosophy

Always prefer:

- Small commits
- Small changes
- Reversible work
- Safe modifications
- Existing architecture
- Stable behavior

Never optimize code that was not requested.

Never redesign code that already works.

When multiple solutions exist, choose the least invasive solution that satisfies the request.

---

These rules are permanent for the FARBERMAKERS project and should be followed automatically in every future task until explicitly changed by the project owner.

---

# 12. UI / UX Standards

Every visual change must improve the user experience.

When changing the interface:

- Maintain visual consistency.
- Keep spacing and alignment consistent.
- Maintain responsive behavior.
- Avoid clutter.
- Prefer modern, clean layouts.
- Match existing colors, typography and components.

Never reduce usability just to simplify implementation.

---

# 13. Performance

Avoid unnecessary DOM operations.

Avoid duplicate event listeners.

Avoid duplicate queries.

Prefer efficient algorithms.

Never optimize prematurely, but never introduce unnecessary performance regressions.

---

# 14. Database Safety

Never modify database schema unless explicitly requested.

Never delete production data.

Never create destructive migrations without approval.

If database changes are required:

Explain:
- why
- risks
- rollback strategy

before executing.

---

# 15. Logging

When adding new functionality:

Add useful console logs during development only when necessary.

Do not leave excessive debug logging in production code.

---

# 16. Comments

Do not add obvious comments.

Only comment code that explains business logic or non-obvious decisions.

Prefer self-explanatory code.

---

# 17. File Organization

Keep project structure organized.

Do not create new files unless necessary.

Reuse existing modules whenever appropriate.

Avoid duplicate utilities.

---

# 18. Error Handling

Never silently ignore errors.

Display user-friendly messages.

Log technical details only when appropriate.

Always fail gracefully.

---

# 19. Communication

Before starting:

Briefly explain the plan.

After finishing:

Explain:

- what changed
- why it changed
- what was verified

Keep explanations concise.

---

# 20. Project Knowledge

When discovering important project rules or business logic during development:

Remember them automatically for future tasks in this repository.

Do not ask me the same implementation question twice if the project already established a standard.

Examples:

- SMS templates
- Customs flow
- Makers Air rules
- Ascend behavior
- Ticket numbering
- Delivery workflow
- Welcome messages
- Dashboard conventions
- UI patterns

Use existing project conventions whenever possible.

---

# 21. Code Quality

Always prefer:

Simple > Complex

Readable > Clever

Explicit > Implicit

Maintainable > Short

Consistency > Personal Preference

---

These rules have the same priority as every other rule in this document.
