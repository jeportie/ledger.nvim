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

## `ci_desktop_golden.txt`

The concrete, non-parameterized DESKTOP test names for the two "Shape-B" specs
targeted by issue #57 milestone 1, extracted from a real desktop CI run. Used as
the golden reference for `M.resolve_desktop` (a static array literal → a `for`
loop → a parameterized Playwright `test.describe`/`test(\`…${x.prop}\`)` title).

The 19 names are:
- `Swap - 1inch flow`, `Swap - OKX flow` — from `provider.swap.spec.ts`'s
  `providerFlowTests` loop (`${provider.uiName}`).
- 17 `[<currency>] Add account` — from `add.account.spec.ts`'s `currencies` loop
  (16, via `${currency.currency.name}`) plus the direct-literal Aleo title
  (`${Currency.ALEO.name}`).

Provenance:
- Desktop run `28432194879` (LedgerHQ/ledger-live), artifact `allure-results`.
  Extraction: `.name` from `*-result.json`, then kept only the 19 names produced
  by the two targeted specs. Other `Swap - … flow` (token approval/reapproval)
  and `… Add account …` names come from OTHER specs and are out of M1 scope.
- Order: `table.sort` (byte order), matching `M.resolve_desktop`'s output — the
  `Swap …` names sort before the `[…]` names (`S` 0x53 < `[` 0x5B). The
  integration test compares as a set, so order is not load-bearing.

Branch delta caveat: same as the swap fixture — the CI run is a newer branch than
the local checkout the resolver reads; this file is CI evidence, and the resolver
is validated against the local checkout.
