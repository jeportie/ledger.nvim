# tests/fixtures

## `ci_swap_golden.txt`

The concrete, non-parameterized swap test names (`^Swap <name> to <name>$`, the
`runSwapTest` Shape-A subset) extracted from a real CI run, used as the golden
reference for the POC resolver (issue #51, milestone 1: SWAP).

Provenance:
- Mobile run `28432343653` (LedgerHQ/ledger-live), artifacts
  `e2e-test-results-android` + `e2e-test-results-ios` (jest results JSON).
  Both platforms produced an identical swap set.
- Extraction: `.testResults[].assertionResults[].title`, kept titles starting
  with `"Swap "`, then dropped the non-`runSwapTest` helpers (token approval,
  "max amount from …", "too low quote …", "using a different seed …", history,
  landing page) which are out of this POC's scope.

Branch delta caveat: the CI run is branch `feat/qaa-703-discreet-mode`
(2026-06-30), NEWER than the local checkout the resolver reads
(`2026-04-08-LedgerHQ-ledger-live`). The simple-swap set happens to match 1:1,
but this file is CI evidence, not a spec — the resolver is validated against the
local checkout and this list is used for a comparison/drift report only.
