# Requirements: astro (example, edit to what you actually want)

## Goal
The calculation library in `src/lib/` produces the same results as PyJHora for real birth data,
so that the horoscope report can be trusted.

## Reference oracle
PyJHora is at `C:/path/to/PyJHora` (put your real path here and in `nightshift.yml`). During
planning (attended), use it to
generate golden fixtures: about 30 births (different decades, both hemispheres, DST and non-DST
time zones, a few edge cases near sign/nakshatra boundaries and midnight). Store visible fixtures in
`spec/test/fixtures/` and a DIFFERENT set of births for the hidden holdout tests. Use the same
ayanamsa (Lahiri) and settings as the app; write them down in AGENTS.md.

## Must have (one task each, smallest first)
- Sidereal longitudes of Sun..Saturn, Rahu/Ketu and the ascendant within 0.01 degrees of PyJHora.
- Rasi (sign) and nakshatra + pada for each planet and the ascendant: exact match.
- Panchanga (tithi, vara, nakshatra, yoga, karana) at birth: exact match.
- Vimshottari dasha: maha and antar dasha sequence with start dates within 1 day of PyJHora.
- Navamsa (D9) positions: exact match.

## Must not
- Change public function signatures used by `src/components` and `src/pages` (add new functions instead).
- Add dependencies or edit test config, fixtures or package files.
- Hard-code fixture values or special-case fixture dates.

## How to verify
- `npx vitest run spec/test/acceptance/<task>.test.ts` per task, comparing against the fixtures.
- Hidden holdout tests use births that are not in the visible fixtures.
- Optional later: `npx tsc --noEmit -p tsconfig.app.json` as a global gate once it is green.

## Out of scope
- UI and styling changes (poor fit for the local model at night; do those attended or with a cloud model).
- The life-purpose / interpretation text.
