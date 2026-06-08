# ledger.nvim

Neovim plugin suite for Ledger Live QA Automation workflows.

Provides in-editor tooling for the [`LedgerHQ/ledger-live`](https://github.com/LedgerHQ/ledger-live)
monorepo: Jira/Xray ticket management, Playwright + Detox test orchestration,
build/process supervision, GitHub PR + Actions boards, Allure result browsing,
and the multi-terminal choreography that QA Automation work on Ledger Live requires.

> Status: pre-alpha. Tracking 25 issues across 4 phases. See
> [Roadmap](#roadmap) below or the
> [issues list](https://github.com/jeportie/ledger.nvim/issues) for current state.

## Requirements

- Neovim ≥ 0.10
- [`nvim-lua/plenary.nvim`](https://github.com/nvim-lua/plenary.nvim)
- [`nvzone/volt`](https://github.com/nvzone/volt) — board rendering engine
- [`nvzone/menu`](https://github.com/nvzone/menu) — context menus
- [`stevearc/overseer.nvim`](https://github.com/stevearc/overseer.nvim) — task orchestration
- [`pwntester/octo.nvim`](https://github.com/pwntester/octo.nvim) — GitHub integration

Environment:
- `JIRA_EMAIL`, `JIRA_API_TOKEN`, `JIRA_URL` for Jira/Xray access
- macOS Keychain item `ledger-e2e-seed` (or `SEED` env var) for E2E test seed
- `COINAPPS` path for Speculos coin apps

## Quickstart (lazy.nvim)

```lua
{
  "jeportie/ledger.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvzone/volt",
    "nvzone/menu",
    "stevearc/overseer.nvim",
    "pwntester/octo.nvim",
  },
  opts = {
    jira = { project_key = "QAA", board_name = "Team QA Automation" },
    xray = { project_key = "B2CQA" },
    monorepo_root = vim.fn.expand("~/src/ledger-live"),
  },
}
```

## Keymaps

Available today:

| Map | Action |
|---|---|
| `<leader>jb` | Jira board (QAA backlog) |
| `<leader>fx` | Xray ticket search (B2CQA) |
| `<leader>xc` | Xray coverage scan |
| `K` | Xray hover on B2CQA-IDs (falls back to LSP hover) |
| `<leader>t*` | Neotest workflow (`ts/tS/to/tO/tr/tf/ta/td/tD/tc/tb/tm` — Detox/Playwright) |

Planned (see Roadmap):

| Map | Action | Tracked in |
|---|---|---|
| `<leader>Lb` | Builder board | [#7](https://github.com/jeportie/ledger.nvim/issues/7) |
| `<leader>Lt` | Test Summary board | [#8](https://github.com/jeportie/ledger.nvim/issues/8) |
| `<leader>Lp` | PR board | [#16](https://github.com/jeportie/ledger.nvim/issues/16) |
| `<leader>Lg` | GitHub Actions board | [#17](https://github.com/jeportie/ledger.nvim/issues/17) |
| `<leader>La` | Allure board | [#21](https://github.com/jeportie/ledger.nvim/issues/21) |
| `<leader>Le` | Ledger env profile picker | [#4](https://github.com/jeportie/ledger.nvim/issues/4) |
| `<leader>Lr` | pnpm script runner picker | [#6](https://github.com/jeportie/ledger.nvim/issues/6) |

See `:h ledger` for the full reference.

## Roadmap

Phases are tracked via GitHub labels [`phase-1`](https://github.com/jeportie/ledger.nvim/labels/phase-1) .. [`phase-4`](https://github.com/jeportie/ledger.nvim/labels/phase-4).

### Phase 0 — Foundation ✅
- ✅ LN-001 chore: bootstrap + migrate from kickstart.nvim ([#1](https://github.com/jeportie/ledger.nvim/issues/1))

### Phase 1 — Test-running stack end-to-end
Goal: from `:LedgerTasks` you can launch Metro + Detox build + iOS/Android test, watch logs, open Allure — without leaving Neovim.

- [ ] LN-002 feat(neotest): bundle Playwright+Detox config + keymaps into the suite ([#3](https://github.com/jeportie/ledger.nvim/issues/3))
- [ ] LN-003 feat(env): Ledger env profiles via environment.nvim ([#4](https://github.com/jeportie/ledger.nvim/issues/4))
- [ ] LN-004 feat(tasks): overseer.nvim + ledger task templates ([#5](https://github.com/jeportie/ledger.nvim/issues/5))
- [ ] LN-005 feat(scripts): pnpm script picker ([#6](https://github.com/jeportie/ledger.nvim/issues/6))
- [ ] LN-006 feat(builder): Builder board ([#7](https://github.com/jeportie/ledger.nvim/issues/7))
- [ ] LN-007 feat(test-summary): Test Summary board ([#8](https://github.com/jeportie/ledger.nvim/issues/8))
- [ ] LN-008 feat(build): build-target picker ([#9](https://github.com/jeportie/ledger.nvim/issues/9))
- [ ] LN-009 feat(artifacts): Allure / Playwright report / trace viewers ([#10](https://github.com/jeportie/ledger.nvim/issues/10))
- [ ] LN-010 feat(xray): `:XrayMarkAutomated` post-merge B2CQA flip ([#11](https://github.com/jeportie/ledger.nvim/issues/11))
- [ ] LN-020 support(refactor): consolidate xray/pickers into ledger.jira.pickers ([#12](https://github.com/jeportie/ledger.nvim/issues/12))
- [ ] LN-026 feat(xray): bundle K-hover override into ledger.nvim setup ([#13](https://github.com/jeportie/ledger.nvim/issues/13))

### Phase 2 — Workflow + boards
Goal: GitHub PR/CI surface, Jira↔branch↔PR linker, persistent process monitoring, Allure flaky tracking.

- [ ] LN-019 feat(common): shared board engine (lands FIRST) ([#14](https://github.com/jeportie/ledger.nvim/issues/14))
- [ ] LN-011 feat(github): wire octo.nvim with ledger-aware extras ([#15](https://github.com/jeportie/ledger.nvim/issues/15))
- [ ] LN-012 feat(pr): PR board ([#16](https://github.com/jeportie/ledger.nvim/issues/16))
- [ ] LN-013 feat(actions): GH Actions board ([#17](https://github.com/jeportie/ledger.nvim/issues/17))
- [ ] LN-014 feat(workflow): `:LedgerStart QAA-XXXX` Jira↔branch↔PR linker ([#18](https://github.com/jeportie/ledger.nvim/issues/18))
- [ ] LN-015 feat(test): triple-run gate command ([#19](https://github.com/jeportie/ledger.nvim/issues/19))
- [ ] LN-016 feat(monitor): floating process monitor widget ([#20](https://github.com/jeportie/ledger.nvim/issues/20))
- [ ] LN-017 feat(allure): Allure board with flaky-test tracking ([#21](https://github.com/jeportie/ledger.nvim/issues/21))
- [ ] LN-018 feat(persistence): state across `:q` ([#22](https://github.com/jeportie/ledger.nvim/issues/22))

### Phase 3 — Polish
- [ ] LN-021 feat(dap): nvim-dap-vscode-js for Playwright + Detox + apps/cli ([#23](https://github.com/jeportie/ledger.nvim/issues/23))
- [ ] LN-022 feat(speculos): REST control panel ([#24](https://github.com/jeportie/ledger.nvim/issues/24))
- [ ] LN-023 feat(triage): 6-bucket failure classification with Slack helper ([#25](https://github.com/jeportie/ledger.nvim/issues/25))

### Phase 4 — Stability + docs
- [ ] LN-024 docs: README sections + `:h ledger` vim help ([#26](https://github.com/jeportie/ledger.nvim/issues/26))
- [ ] LN-025 test(ci): plenary suite + GitHub Action matrix ([#27](https://github.com/jeportie/ledger.nvim/issues/27))

## Origin

Initially extracted from [`jeportie/kickstart.nvim`](https://github.com/jeportie/kickstart.nvim)
where the Jira/Xray/Detox tooling lived under `lua/jira-board/`, `lua/xray/`,
`lua/lib/jira/`, and `lua/lib/detox.lua`.

## License

MIT.