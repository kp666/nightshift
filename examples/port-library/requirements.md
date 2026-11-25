# Requirements: my-app (example, edit to what you actually want)

## Goal
The calculation module in `src/lib/` produces the same results as the reference library for real
inputs, so that the reports built on it can be trusted.

## Reference oracle
The reference library is at `/path/to/reference-lib` (put your real path here and in
`nightshift.yml`). During planning (attended), use it to generate golden fixtures: about 30 inputs
(spread over the whole input range, plus a few edge cases near boundaries such as midnight, month
ends and range limits). Store visible fixtures in `spec/test/fixtures/` and a DIFFERENT set of
inputs for the hidden holdout tests. Use the same settings as the app; write them down in
AGENTS.md.

## Must have (one task each, smallest first)
- The core numeric results within 0.01 of the reference.
- The derived categories (which bucket, band or index a value falls in): exact match.
- The derived dates and periods: start dates within 1 day of the reference.

## Must not
- Change public function signatures used by `src/components` and `src/pages` (add new functions instead).
- Add dependencies or edit test config, fixtures or package files.
- Hard-code fixture values or special-case fixture inputs.

## How to verify
- `npx vitest run spec/test/acceptance/<task>.test.ts` per task, comparing against the fixtures.
- Hidden holdout tests use inputs that are not in the visible fixtures.
- Optional later: `npx tsc --noEmit -p tsconfig.app.json` as a global gate once it is green.

## Out of scope
- UI and styling changes (poor fit for the local model at night; do those attended or with a cloud model).
- Any text written for people to read (explanations, interpretations).
