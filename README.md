# ledger.nvim

Neovim plugin suite for Ledger Live QA Automation workflows.

Provides in-editor tooling for the [`LedgerHQ/ledger-live`](https://github.com/LedgerHQ/ledger-live)
monorepo: Jira/Xray ticket management, Playwright + Detox test orchestration,
build/process supervision, GitHub PR + Actions boards, Allure result browsing,
and the multi-terminal choreography that QA Automation work on Ledger Live requires.

> Status: pre-alpha. Tracking 25 issues across 4 phases. See
> [Roadmap](#roadmap) below or the
> [issues list](https://github.com/jeportie/ledger.nvim/issues) for current state.

## Contents

- [Requirements](#requirements)
- [Quickstart](#quickstart-lazynvim)
- [Features](#features)
  - [Jira & Xray ticket management](#jira--xray-ticket-management)
  - [Test orchestration](#test-orchestration)
  - [Boards (UI)](#boards-ui)
  - [Build & process supervision](#build--process-supervision)
  - [GitHub workflow](#github-workflow)
  - [Test artifacts & reports](#test-artifacts--reports)
  - [Environment & scripts](#environment--scripts)
  - [Debug](#debug)
  - [Triage](#triage)
- [Configuration](#configuration)
- [Keymaps cheat-sheet](#keymaps-cheat-sheet)
- [Roadmap](#roadmap)
- [Origin](#origin)
- [License](#license)

## Requirements

- Neovim ≥ 0.10
- [`nvim-lua/plenary.nvim`](https://github.com/nvim-lua/plenary.nvim) — HTTP via `curl`, async utils
- [`nvzone/volt`](https://github.com/nvzone/volt) — board rendering engine
- [`nvzone/menu`](https://github.com/nvzone/menu) — context menus
- [`stevearc/overseer.nvim`](https://github.com/stevearc/overseer.nvim) — task orchestration *(Phase 1)*
- [`pwntester/octo.nvim`](https://github.com/pwntester/octo.nvim) — GitHub integration *(Phase 2)*

Environment:

- `JIRA_EMAIL`, `JIRA_API_TOKEN`, `JIRA_URL` — Atlassian credentials for Jira/Xray API
- macOS Keychain item `ledger-e2e-seed` (or `SEED` env var) — BIP39 seed for E2E tests
- `COINAPPS` — path to the cloned `LedgerHQ/coin-apps` repo (Speculos coin binaries)
- `SPECULOS_DEVICE` (`nanoSP` / `nanoX` / `stax` / `flex`), `SPECULOS_IMAGE_TAG` — Speculos config
- `MOCK`, `DISABLE_TRANSACTION_BROADCAST` — runtime flags propagated to test adapters

External tools used by the plugin (`gh`, `op`, `docker`, `adb`, `xcrun simctl`, `lsof`) are expected to be on `PATH` when their respective features are invoked.

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

For local plugin development (working on `ledger.nvim` itself), point lazy at the local checkout:

```lua
{
  "jeportie/ledger.nvim",
  dir = vim.fn.expand("~/src/ledger.nvim"),
  -- ...
}
```

## Features

Legend: ✅ available · 🚧 in development · 📋 planned · numbers in brackets link to the tracking issue.

### Jira & Xray ticket management

#### Jira board — `<leader>jb` ✅
<img width="1386" height="1083" alt="Screenshot 2026-06-08 at 15 50 20" src="https://github.com/user-attachments/assets/f68751f8-9836-407b-b6eb-bc2eaf33fe76" />
A floating kanban window for the QAA project, grouped by **epic bands** with collapsible groups and a sticky winbar showing the active filter chips. Cards display: ticket key, summary, status icon, priority, assignee avatar, labels.

**In-board keymaps:**

| Key | Action |
|---|---|
| `h` / `l` / `<Tab>` / `<S-Tab>` | move between columns |
| `j` / `k` | move card focus up/down |
| `<CR>` / `p` / `<2-LeftMouse>` | preview ticket (description, priority, labels) in float |
| `b` | open ticket in browser |
| `y` | yank ticket key to clipboard |
| `R` | refresh board from Jira |
| `A` | toggle assignee filter (me ↔ all) |
| `B` | toggle backlog column |
| `f` | open multi-category filter picker (assignee / epic / type / label) |
| `t` | transition status (status picker) |
| `m` | assign to me |
| `a` | assign to other (debounced user search) |
| `u` | unassign |
| `z` / `Z` | collapse / expand current epic (or all) |
| `?` | help float |
| `q` / `<Esc>` | close |
| `<RightMouse>` | context menu |

Backed by a shared HTTP client at `lua/ledger/jira/{api,agile,adf,util,icons,config}.lua`. ADF (Atlassian Document Format) is converted to plain-text lines for preview rendering. Credentials read from env at call time; no token is stored in the plugin.

#### Xray ticket browser — `<leader>fx`, `<leader>xc`, `K`-hover ✅

For the **B2CQA** test-case project (Xray TMS):

- **`<leader>fx`** — three-pane Telescope-style picker with prompt + results + ticket-detail pane. Supports inline filter shortcuts in the prompt: `status:`, `assignee:`, `priority:`, `platforms:`, `team:`, `type:`. The detail pane shows the ticket's full description, steps, links, and labels as you arrow through results.
- **`<leader>xc`** — coverage scanner. Given a `B2CQA-XXXX` ticket id (cursor word or prompt), runs `rg` over the local `ledger-live` checkout and shows desktop/mobile/other reference counts with jump-to-location. Useful for "is this test already automated?".
- **`K`** — hover override. If the cursor is on a `B2CQA-XXXX` word, opens the Xray hover popup with the ticket's status, preconditions, steps, and a navigation stack (drill into linked tickets without losing your place). Otherwise falls back to the configured LSP hover (Lspsaga by default).

#### `:XrayMarkAutomated B2CQA-XXXX [LLD|LLM|LLC|LiveApp]` 📋 [#11](https://github.com/jeportie/ledger.nvim/issues/11)

Post-merge command that flips a B2CQA test from `Manual Test` → `Automated` and sets the `Automated In` field. Two modes:

- explicit ticket key + platform tag
- no arguments: parses the current branch name (`feat/qaa-XXX-...`) → finds linked B2CQAs from spec annotations → offers per-ticket `Y/A/N` flip confirmation

Closes the most-missed step in the Ledger QA workflow (listed as a top-5 intern mistake in the QA onboarding guide).

#### K-hover bundling 📋 [#13](https://github.com/jeportie/ledger.nvim/issues/13)

Currently the K-key override delegating to Xray lives in user LSP config. This feature exposes `require("ledger.xray").attach_hover_override()` so the plugin self-installs the override on `LspAttach`, eliminating the need for users to maintain their own K-binding.

### Test orchestration

#### Neotest integration ✅

Configures `nvim-neotest/neotest` with four Ledger-aware adapters:

- **Vitest** — unit tests anywhere (`vitest.config.ts` root pattern)
- **CTest** — CMake tests (for native libraries)
- **Playwright** — desktop E2E (`e2e/desktop/`). Injects `MOCK`, `SEED`, `COINAPPS`, `SPECULOS_IMAGE_TAG`, `SPECULOS_DEVICE`, `DISABLE_TRANSACTION_BROADCAST`. Spec match: `e2e/desktop/.*%.spec%.ts$`.
- **Jest/Detox** — mobile E2E (`e2e/mobile/`). Builds `detox test -c <config> --` with the currently-selected configuration. Spec match: `e2e/mobile/specs/.*%.spec%.ts$`.

Exposes:

```lua
require("ledger.neotest").apply(opts)        -- merge adapters/consumers/augment into neotest opts
require("ledger.neotest").register_commands()  -- :NeotestDetox{Platform,Build,Metro} + :NeotestSmartRun
```

#### SEED resolution ✅

The E2E test seed is resolved lazily and cached for the nvim session, gated on `in_ledger_live()` (only fetches when the cwd is actually a `ledger-live` repo):

1. `$SEED` env var if set
2. macOS Keychain item `ledger-e2e-seed` via `security find-generic-password -a "$USER" -s ledger-e2e-seed -w`
3. Warn and return empty string (the test will fail downstream with a clear "no seed" message)

#### Detox helpers ✅

`require("ledger.detox")` exposes:

- `platform_labels` (`ios` / `android` / `both`), `config.platform` getter/setter
- `get_e2e_desktop_root()` / `get_e2e_mobile_root()` — repo-aware path resolution
- `build(config)` — invokes `pnpm mobile e2e:build` with the right configuration
- `start_metro()` — toggles the Metro bundler in a horizontal split, with port-collision detection via `lsof -i :8081`
- `smart_run(scope)` — pre-checks (build artifact exists, Metro alive if needed, "both" platform sequencing) before running neotest
- `on_results` — aggregator for "both" mode that chains iOS → Android runs and reports a combined pass/fail

User commands installed:

- `:NeotestDetoxPlatform` — pick iOS / Android / Both
- `:NeotestDetoxBuild [config]` — build with `pnpm mobile e2e:build`
- `:NeotestDetoxMetro` — toggle Metro bundler split
- `:NeotestSmartRun [nearest|file|all]` — smart run with Detox pre-checks

#### Playwright & Detox debug flags ✅

- `<leader>td` / `<leader>tD` — run nearest / file with Playwright `--debug` (opens the Playwright Inspector)
- In `neotest-summary` filetype: `p` re-runs with Playwright `--debug`, `P` re-runs with Detox trace logs (`DEBUG_DETOX=1` + `--loglevel trace`)

The debug flags are injected via a `vim.g._neotest_*_debug` global captured in neotest's `opts.run.augment` hook — clean separation from neotest's own keymaps.

#### Test Summary board — `<leader>Lt` 📋 [#8](https://github.com/jeportie/ledger.nvim/issues/8)

Kanban dashboard of test executions. Each spec run = card. Lifecycle Queued → Running → Passed/Failed/Skipped. Companion to `:Neotest summary` (the sidebar stays as tree navigator; the board is the dashboard).

Tied to the [Builder board](#builder-board--leaderlb-) for prerequisite checks ("needs Metro [healthy]", "build is stale"). Card actions: rerun, debug (Inspector / trace), view log, view artifact, open Allure, jump to spec.

#### Triple-run gate — `:LedgerTripleRun` 📋 [#19](https://github.com/jeportie/ledger.nvim/issues/19)

Runs the current spec 3 times sequentially, aggregates results in a report buffer. Implements the documented Ledger QA rule "minimum 3 local runs before opening a PR". Refuses to mark a run green if any retry occurred.

### Boards (UI)

All boards share a single rendering engine (`lua/ledger/ui/board.lua`, extracted in [#14](https://github.com/jeportie/ledger.nvim/issues/14)) and use `nvzone/volt` for cell-based painting + `nvzone/menu` for context menus. They follow the visual conventions established by the existing Jira board.

#### Builder board — `<leader>Lb` 📋 [#7](https://github.com/jeportie/ledger.nvim/issues/7)

Long-running infrastructure cards: Metro · Speculos containers · Detox build · Playwright run · library `--watch` · `dev:lld` · `dev:llm` · `pnpm install` · `pod install` · `gradle assemble`. Backed by `overseer.nvim` task templates ([#5](https://github.com/jeportie/ledger.nvim/issues/5)).

**Columns:** `Queued / Running / Failed / Done`
**Card actions:** `<CR>` view live log · `r` restart · `x` kill · `y` yank command · `t` change target (debug/release/prerelease) · `p` change platform · `R` refresh

Solves the "9-terminal QA flow" documented in the onboarding guide (Metro + Speculos + Detox bridge + emulator + adb reverse + ...) by giving you a single dashboard view.

#### PR board — `<leader>Lp` 📋 [#16](https://github.com/jeportie/ledger.nvim/issues/16)

Pull requests for the active monorepo. Kanban over `gh pr list --json` with live polling.

**Columns:** `Mine / Review-requested / Draft / Open / Recently-merged`
**Card actions:** `<CR>` open in octo · `c` view checks · `b` open in browser · `r` request review / mark ready · `m` merge (if mergeable + approved) · `y` yank URL
**Cross-board link:** `j` on a card → jump to matching Jira ticket (parses `qaa-XXX` from branch name)

#### GitHub Actions board — `<leader>Lg` 📋 [#17](https://github.com/jeportie/ledger.nvim/issues/17)

Workflow runs for the current branch + recent runs across branches. Kanban over `gh run list --json` with live polling while runs are active.

**Columns:** `Queued / Running / Failed / Success`
**Card actions:** `<CR>` open run logs in float · `R` rerun failed jobs only · `b` open in browser · `w` watch live (tail) · `c` view checks for current PR
**Cross-board link:** `g` on a PR-board card → list that PR's runs here

#### Allure board — `<leader>La` 📋 [#21](https://github.com/jeportie/ledger.nvim/issues/21)

Parses `e2e/{desktop,mobile}/allure-results/*.json` (or in-app suite paths). Groups results by epic/feature/suite with collapsible bands (mirroring the Jira board's epic UX).

**Columns:** `Passed / Failed / Broken / Skipped / Flaky`
**Card actions:** `<CR>` detail float (steps, screenshots, video, Speculos screenshot, attached logs) · `s` open screenshot · `v` open video · `t` open trace (`npx playwright show-trace`) · `j` jump to spec source · `F` flaky-test report → file GH issue · `b` open Allure web report

Persists outcomes across nvim sessions at `stdpath('data')/ledger_allure_history.json` → the `Flaky` bucket auto-populates from history.

### Build & process supervision

#### Overseer task templates 📋 [#5](https://github.com/jeportie/ledger.nvim/issues/5)

Installs [`stevearc/overseer.nvim`](https://github.com/stevearc/overseer.nvim) and defines named, persistent task templates for:

- Metro bundler (`pnpm mobile start`)
- Detox build (per `--configuration` value)
- Playwright run / shard (with `--shard=I/N` parameterization)
- Library `--watch` (`pnpm --filter @ledgerhq/<lib> run watch`)
- Dev servers (`pnpm dev:lld`, `pnpm dev:llm`)
- One-shots (`pnpm install`, `pnpm mobile pod`, `gradle assemble`)

The Detox helpers (`ledger.detox.start_metro()` etc.) migrate from ad-hoc `vim.fn.termopen` to overseer strategies so termination, restart, and log-tail are uniform across processes. Exposes `:LedgerTasks` picker.

#### Build-target picker 📋 [#9](https://github.com/jeportie/ledger.nvim/issues/9)

A floating picker pre-populated with the canonical build matrix:

- Detox: `ios.sim.{debug,release,prerelease}`, `android.emu.{debug,release,prerelease}`
- Desktop: `testing` / `staging` / `prod` / `nightly` / `pre` / `release`

Picked target persists per-workspace and integrates with the Builder board task templates.

#### Process monitor — `:LedgerMonitor` 📋 [#20](https://github.com/jeportie/ledger.nvim/issues/20)

Small floating window (or statusline section) showing live status of Metro (port 8081), Detox bridge (port 8099), Speculos containers (`docker ps`), last build (timestamp + state), Allure server. Polls `lsof -i :PORT` + `docker ps --filter name=speculos`. Auto-hides when no Ledger work is active.

#### State persistence 📋 [#22](https://github.com/jeportie/ledger.nvim/issues/22)

Persists across nvim sessions: Metro PID + port · last Detox configuration + platform pick · last selected env profile · Builder board card states · last build artifact paths. On startup, re-attaches to processes if still alive (PID + port check); clears stale state otherwise.

### GitHub workflow

#### octo.nvim integration 📋 [#15](https://github.com/jeportie/ledger.nvim/issues/15)

Wires [`pwntester/octo.nvim`](https://github.com/pwntester/octo.nvim) for in-editor PR / issue / review comment management. Adds Ledger-aware commands on top:

- `:LedgerPRForTicket QAA-1129` — search PRs whose branch matches `*qaa-1129*` or whose body contains the ticket
- `:LedgerCI` — show `gh pr checks` for the current branch
- `:LedgerRerunFailed` — re-run only the failed jobs via `gh run rerun --failed`

#### Jira ↔ branch ↔ PR linker 📋 [#18](https://github.com/jeportie/ledger.nvim/issues/18)

- `:LedgerStart QAA-1129` — creates branch `feat/qaa-1129-<slugified-summary>` from `develop`, opens the Jira board scrolled to the ticket
- `:LedgerOpenJira` — from a feature branch, parses the branch name back to a QAA ticket and opens it in the Jira board / browser
- `:LedgerLinkPR` — posts a comment on the QAA ticket linking the current PR

Implements the ticket-to-merge flow documented in the QA onboarding guide. Branch naming follows the Ledger Live conventions (`feat/qaa-XXX-...`, `feat/llm-qaa-XXX-...` for mobile-scoped work).

### Test artifacts & reports

#### Allure / Playwright HTML report / Trace viewers 📋 [#10](https://github.com/jeportie/ledger.nvim/issues/10)

Quality-of-life commands for the three main artifact viewers used during failure triage:

- `:LedgerAllure desktop|mobile` — runs `pnpm allure` from the right workspace and opens the web UI
- `:LedgerReport` — opens `e2e/desktop/playwright-report/index.html` (or mobile equivalent) in browser
- `:LedgerTrace <file>` — runs `npx playwright show-trace <file>`
- `:LedgerScreenshot <test-id>` — opens the Detox screenshot for a test in the system image viewer

Smart workspace detection works from any cwd inside the monorepo.

### Environment & scripts

#### Ledger env profiles — `<leader>Le` 📋 [#4](https://github.com/jeportie/ledger.nvim/issues/4)

Picker over named env-var profiles, persisted per nvim session and rendered in the statusline. Profiles bundle related env vars so you do not have to remember every flag:

```lua
require("ledger.env").setup({
  profiles = {
    ["mobile-debug-ios"]   = { ENVFILE = ".env.mock", DETOX_CONFIGURATION = "ios.sim.debug",   MOCK = "0", ... },
    ["mobile-release-and"] = { ENVFILE = ".env.mock", DETOX_CONFIGURATION = "android.emu.release", ... },
    ["mobile-prerelease"]  = { ENVFILE = ".env.mock.prerelease", ... },
    ["desktop-testing"]    = { TESTING = "1", ... },
    ["desktop-staging"]    = { STAGING = "1", ... },
    ["dev-lld-mock"]       = { ENABLE_MSW = "true", ... },
    ["cli-no-broadcast"]   = { DISABLE_TRANSACTION_BROADCAST = "1", ... },
  },
  defaults = {
    COINAPPS = vim.env.COINAPPS or "~/coin-apps",
    SPECULOS_DEVICE = "nanoSP",
    NODE_OPTIONS = "--max-old-space-size=8192",
  },
})
```

Backed by [`environment.nvim`](https://github.com/Alexandersfg4/environment.nvim) for the variable substitution layer.

#### pnpm script picker — `<leader>Lr` 📋 [#6](https://github.com/jeportie/ledger.nvim/issues/6)

Reads all `package.json` scripts under the monorepo (`apps/*`, root, `e2e/*`) and presents a picker grouped by app/workspace. `live-mobile` exposes ~80 scripts and `live-desktop` ~30 — this surfaces them with search-as-you-type and "recent picks at the top". Selecting runs the script via overseer ([#5](https://github.com/jeportie/ledger.nvim/issues/5)).

### Debug

#### DAP for Playwright / Detox / apps/cli 📋 [#23](https://github.com/jeportie/ledger.nvim/issues/23)

Installs [`mxsdev/nvim-dap-vscode-js`](https://github.com/mxsdev/nvim-dap-vscode-js) and configures it for the monorepo so source-level breakpoints work in Playwright specs, Detox specs, and `apps/cli`. Today only Playwright's `--debug` (Inspector) and Detox's trace mode are available — this adds real DAP UI, watch expressions, and step-into.

Adds `:LedgerDapAttach` for attaching to running Metro / node processes.

#### Speculos REST control panel — `:LedgerSpeculos [port]` 📋 [#24](https://github.com/jeportie/ledger.nvim/issues/24)

Floating panel wrapping the Speculos REST API: `/screenshot` (live preview) · `/button/{left,right,both}` · `/finger` · `/automation` · `/events` tail. Port auto-detected from the currently-running test (env var or `docker ps`). Useful for manual hardware-walk reproduction when a test diverges.

### Triage

#### 6-bucket failure classification — `:LedgerTriage` 📋 [#25](https://github.com/jeportie/ledger.nvim/issues/25)

Form-driven helper for the daily-12:00 Monitor role. Takes an Allure URL or failure summary, walks you through the 6-bucket classification documented in the QA onboarding guide:

| Bucket | Owner / Action |
|---|---|
| Bug | `LIVE` ticket + `qaa` label + platform |
| Process-gap | contact owning squad; do not silently patch tests |
| Flaky | Flaky Test Reporter → auto-files GH issue |
| Infra | tag `@qa-automation` in Slack; PE ticket if sustained |
| External | post in `#explorer-users` |
| Operational | tag `@qa-automation` in `#live-repo-health` |

Each bucket posts to its configured Slack channel. Drafts can be saved to a scratch buffer for review before sending.

## Configuration

Full config schema with defaults:

```lua
require("ledger").setup({
  -- Jira project + board to render with `<leader>jb`
  jira = {
    project_key  = "QAA",
    board_name   = "Team QA Automation",
  },

  -- Xray (Atlassian Test Management) project
  xray = {
    project_key  = "B2CQA",
  },

  -- Path to the ledger-live monorepo (overrides cwd-walking heuristic)
  monorepo_root = nil,

  -- Path to the cloned LedgerHQ/coin-apps repo (for Speculos)
  coinapps_path = nil,

  -- Speculos defaults
  speculos = {
    device    = "nanoSP",
    image_tag = "ghcr.io/ledgerhq/speculos:latest",
  },

  -- E2E test seed resolution
  seed = {
    keychain_service = "ledger-e2e-seed",  -- security find-generic-password -s <this>
    env_var          = "SEED",             -- fallback env var
  },
})
```

For Jira/Xray auth, set these env vars in your shell rc:

```sh
export JIRA_EMAIL="your.name@ledger.fr"
export JIRA_API_TOKEN="..."  # https://id.atlassian.com/manage-profile/security/api-tokens
export JIRA_URL="https://ledgerhq.atlassian.net"
```

For the E2E seed, prefer macOS Keychain over env vars:

```sh
security add-generic-password -a "$USER" -s ledger-e2e-seed -w "<24-word BIP39 seed>"
```

## Keymaps cheat-sheet

Available today:

| Map | Action |
|---|---|
| `<leader>jb` | Jira board (QAA backlog) |
| `<leader>fx` | Xray ticket search (B2CQA) |
| `<leader>xc` | Xray coverage scan |
| `K` | Xray hover on B2CQA-IDs (falls back to LSP hover) |
| `<leader>t*` | Neotest workflow (`ts/tS/to/tO/tr/tf/ta/td/tD/tc/tb/tm` — Detox/Playwright) |

Planned (`<leader>L*` namespace):

| Map | Feature | Issue |
|---|---|---|
| `<leader>Lb` | Builder board | [#7](https://github.com/jeportie/ledger.nvim/issues/7) |
| `<leader>Lt` | Test Summary board | [#8](https://github.com/jeportie/ledger.nvim/issues/8) |
| `<leader>Lp` | PR board | [#16](https://github.com/jeportie/ledger.nvim/issues/16) |
| `<leader>Lg` | GitHub Actions board | [#17](https://github.com/jeportie/ledger.nvim/issues/17) |
| `<leader>La` | Allure board | [#21](https://github.com/jeportie/ledger.nvim/issues/21) |
| `<leader>Le` | Ledger env profile picker | [#4](https://github.com/jeportie/ledger.nvim/issues/4) |
| `<leader>Lr` | pnpm script runner picker | [#6](https://github.com/jeportie/ledger.nvim/issues/6) |

See `:h ledger` for the full reference (`doc/ledger.txt`).

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
