# ledger.nvim

Neovim plugin suite for Ledger Live QA Automation workflows.

Provides in-editor tooling for the [`LedgerHQ/ledger-live`](https://github.com/LedgerHQ/ledger-live)
monorepo: Jira/Xray ticket management, Playwright + Detox test orchestration,
build/process supervision, GitHub PR + Actions boards, Allure result browsing,
and the multi-terminal choreography that QA Automation work on Ledger Live requires.

> Status: pre-alpha. Tracking ~25 issues across 5 phases. See the project board
> for current state.

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

| Map | Action |
|---|---|
| `<leader>Lj` | Jira board (QAA backlog) |
| `<leader>Lb` | Builder board (in dev) |
| `<leader>Lp` | PR board (in dev) |
| `<leader>Lg` | GitHub Actions board (in dev) |
| `<leader>La` | Allure board (in dev) |
| `<leader>fx` | Xray ticket search (B2CQA) |
| `<leader>xc` | Xray coverage scan |
| `K` | Xray hover on B2CQA-IDs (falls back to LSP hover) |

See `:h ledger` for the full reference.

## Origin

Initially extracted from [`jeportie/kickstart.nvim`](https://github.com/jeportie/kickstart.nvim)
where the Jira/Xray/Detox tooling lived under `lua/jira-board/`, `lua/xray/`,
`lua/lib/jira/`, and `lua/lib/detox.lua`.

## License

MIT.