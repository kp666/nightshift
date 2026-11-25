# Requirements

## Goal
What should exist tomorrow morning that does not exist now?

## Must have
- Concrete, testable behaviours: "function X(a, b) returns ... for ...", not "improve X".

## Must not
- Choices only you can make that change the plan, e.g. "keep the signature of parse() in src/api.ts".
  No need to repeat the harness's rules: the worker already cannot install packages, use the
  network, or edit protected files.

## How to verify
- Reference implementation, known-good examples, golden data, commands that must pass.

## Out of scope
- What waits for later. If unsure, leave it empty: the planner proposes a scope and asks you.
