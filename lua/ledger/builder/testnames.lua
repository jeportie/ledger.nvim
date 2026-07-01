-- ledger.builder.testnames
--
-- POC (issue #51, milestone 1: SWAP only). Statically resolves the Builder's
-- "run test by name" template-literal titles into concrete jest test names.
--
-- The Builder's picker (see builder/init.lua `pick_test_name`) scrapes titles
-- with a regex and passes them verbatim to `-t`/`--grep`. For parameterized
-- suites the title is a template literal, e.g. in e2e/mobile/specs/swap/swap.ts:
--     it(`Swap ${accountToDebit.currency.name} to ${accountToCredit.currency.name}`, …)
-- so the picker offers a name with a literal `${…}` that never matches a run.
--
-- This module resolves that ONE shape (Shape-A: `runSwapTest(debit, credit, …)`
-- callers) into concrete names like "Swap Bitcoin to Ethereum" by evaluating the
-- e2e enums statically:
--   Account.ETH_1 → Currency.ETH → "Ethereum"
-- Everything is a PURE function of file contents (or a root path that is read
-- once), so the parsers are unit-testable with tiny inline fixtures — the CI
-- runners do NOT have the monorepo checked out.
--
-- Deferred (NOT this PR): wiring into the picker; earn/stake and other helpers;
-- desktop specs; ternary titles (e.g. the XRP amount branch inside the body).

local uv = vim.uv or vim.loop

local M = {}

-- ── low-level helpers ──────────────────────────────────────────────────────

-- Read a file into a single string, or nil if absent/unreadable. Kept tiny so
-- callers can inject contents directly in tests instead of touching disk.
local function read_file(path)
  if not path or not uv.fs_stat(path) then
    return nil
  end
  local lines = vim.fn.readfile(path)
  if type(lines) ~= "table" then
    return nil
  end
  return table.concat(lines, "\n")
end

-- ── enum evaluator ─────────────────────────────────────────────────────────

-- Parse `Currency.ts` contents → { name = { SYM = "Display Name" },
-- ticker = { SYM = "TICK" } }. A currency is declared as
--   static readonly <SYM> = new Currency("<name>", "<ticker>", …)
-- possibly spread over several lines, so we anchor on the declaration and then
-- capture the first two string literals that follow it (before the next
-- declaration). Ticker literals can contain non-ASCII (e.g. "𝚝BTC"), so the
-- string capture is "anything that isn't a quote".
function M.parse_currencies(src)
  local name, ticker = {}, {}
  if type(src) ~= "string" then
    return { name = name, ticker = ticker }
  end
  -- Split on each `new Currency(` so a chunk holds exactly one constructor's
  -- args (up to the next declaration). We still need the SYM, which sits just
  -- before `= new Currency(`.
  for sym, args in src:gmatch("readonly%s+([%w_]+)%s*=%s*new%s+Currency%((.-)%)%s*;") do
    -- First two double-quoted literals = name, ticker.
    local lits = {}
    for lit in args:gmatch('"([^"]*)"') do
      lits[#lits + 1] = lit
      if #lits == 2 then
        break
      end
    end
    if lits[1] then
      name[sym] = lits[1]
    end
    if lits[2] then
      ticker[sym] = lits[2]
    end
  end
  return { name = name, ticker = ticker }
end

-- Parse `Account.ts` contents → { SYM = "CURRENCY_SYM" }. Both plain accounts
-- and token accounts take the `Currency.<X>` reference as their first ctor arg:
--   static readonly ETH_1      = new Account(Currency.ETH, "Ethereum 1", …)
--   static readonly ETH_USDC_1 = new TokenAccount(Currency.ETH_USDC, …)
-- We anchor on either constructor and capture the first `Currency.<SYM>`.
function M.parse_accounts(src)
  local account_currency = {}
  if type(src) ~= "string" then
    return account_currency
  end
  for sym, args in src:gmatch("readonly%s+([%w_]+)%s*=%s*new%s+Account%((.-)%)%s*;") do
    local cur = args:match("Currency%.([%w_]+)")
    if cur then
      account_currency[sym] = cur
    end
  end
  for sym, args in src:gmatch("readonly%s+([%w_]+)%s*=%s*new%s+TokenAccount%((.-)%)%s*;") do
    local cur = args:match("Currency%.([%w_]+)")
    if cur then
      account_currency[sym] = cur
    end
  end
  return account_currency
end

-- Resolve an account symbol (e.g. "ETH_1") to its currency display name
-- ("Ethereum") given the two maps from the parsers. Returns nil if unresolved.
function M.account_name(sym, currencies, accounts)
  local cur = accounts and accounts[sym]
  if not cur then
    return nil
  end
  return currencies and currencies.name and currencies.name[cur] or nil
end

-- ── swap helper title template ─────────────────────────────────────────────

-- Extract the swap `it(`…`)` title template + the ordered placeholder param
-- names from `swap.ts` contents. Returns { template = "Swap %s to %s",
-- params = { "accountToDebit", "accountToCredit" } } — the template has each
-- `${<param>.currency.name}` replaced by `%s` in source order, and `params`
-- lists the param each `%s` came from (so the resolver knows which call arg
-- feeds which slot). Returns nil if no such template is found.
--
-- Only `${<ident>.currency.name}` interpolations are understood; a template
-- containing any other interpolation (a ternary, a different property) is
-- rejected (nil) so we never emit a half-resolved name.
function M.parse_swap_title(src)
  if type(src) ~= "string" then
    return nil
  end
  -- Grab the first backtick title inside an it(`…`) whose text starts with
  -- "Swap " (the Shape-A helper). Non-greedy up to the closing backtick.
  local raw = src:match("it%(%s*`(Swap[^`]*)`")
  if not raw then
    return nil
  end
  local params = {}
  local ok = true
  local template = raw:gsub("%${([^}]*)}", function(expr)
    -- expr must be exactly `<ident>.currency.name`
    local ident = expr:match("^%s*([%w_]+)%.currency%.name%s*$")
    if not ident then
      ok = false
      return "${" .. expr .. "}" -- leave it; we'll bail below
    end
    params[#params + 1] = ident
    return "\0" -- placeholder sentinel (can't appear in source)
  end)
  if not ok then
    return nil
  end
  -- Turn sentinels into "%s" AFTER escaping any literal "%" in the surrounding
  -- text so string.format stays safe (titles have none today, but be robust).
  template = template:gsub("%%", "%%%%"):gsub("%z", "%%s")
  return { template = template, params = params }
end

-- ── Shape-A caller resolver ────────────────────────────────────────────────

-- Parse the ordered account-symbol argument pairs out of every
-- `runSwapTest(ARG1, ARG2, …)` call in a spec's contents. Returns a list of
-- { debit = "ETH_1", credit = "BTC_NATIVE_SEGWIT_1" }. Both `Account.X` and
-- `TokenAccount.X` are accepted for either position.
function M.parse_swap_calls(src)
  local calls = {}
  if type(src) ~= "string" then
    return calls
  end
  for args in src:gmatch("runSwapTest%((.-)%)") do
    -- Pull the ordered (Account|TokenAccount).<SYM> refs; the first two are the
    -- debit/credit accounts (later args are tmsLinks/tags/fee).
    local syms = {}
    for sym in args:gmatch("[%w_]*Account%.([%w_]+)") do
      syms[#syms + 1] = sym
      if #syms == 2 then
        break
      end
    end
    if syms[1] and syms[2] then
      calls[#calls + 1] = { debit = syms[1], credit = syms[2] }
    end
  end
  return calls
end

-- Given resolved enum maps + the title template + a debit/credit pair, produce
-- the concrete title, or nil if either account can't be resolved.
local function render(title, currencies, accounts, call)
  local debit = M.account_name(call.debit, currencies, accounts)
  local credit = M.account_name(call.credit, currencies, accounts)
  if not debit or not credit then
    return nil
  end
  -- params order tells us which arg each %s consumes; for Shape-A it's always
  -- {debit, credit}, but honor the parsed order rather than assuming.
  local slot = { accountToDebit = debit, accountToCredit = credit }
  local values = {}
  for _, p in ipairs(title.params) do
    values[#values + 1] = slot[p] or ""
  end
  return string.format(title.template, unpack(values))
end

-- ── public entry point ─────────────────────────────────────────────────────

-- Default monorepo-relative locations (verified against the 2026-04-08 checkout).
local ENUM_DIR = "libs/ledger-live-common/src/e2e/enum"
local SWAP_DIR = "e2e/mobile/specs/swap"

-- Resolve every Shape-A swap test name from a monorepo checkout at `root`.
-- Returns a SORTED, de-duplicated list of concrete names. `opts` (optional):
--   { enum_dir=, swap_dir=, helper=, currency_file=, account_file= } to
--   override paths (used by the integration test / future callers). On any
--   missing input it returns {} rather than erroring, so callers can treat an
--   empty result as "monorepo unavailable".
function M.resolve_swap(root, opts)
  opts = opts or {}
  if type(root) ~= "string" or root == "" then
    return {}
  end
  local enum_dir = opts.enum_dir or (root .. "/" .. ENUM_DIR)
  local swap_dir = opts.swap_dir or (root .. "/" .. SWAP_DIR)

  local currency_src = read_file(opts.currency_file or (enum_dir .. "/Currency.ts"))
  local account_src = read_file(opts.account_file or (enum_dir .. "/Account.ts"))
  local helper_src = read_file(opts.helper or (swap_dir .. "/swap.ts"))
  if not currency_src or not account_src or not helper_src then
    return {}
  end

  local currencies = M.parse_currencies(currency_src)
  local accounts = M.parse_accounts(account_src)
  local title = M.parse_swap_title(helper_src)
  if not title then
    return {}
  end

  local seen, names = {}, {}
  local specs = vim.fn.glob(swap_dir .. "/*.spec.ts", true, true)
  for _, spec in ipairs(specs) do
    local spec_src = read_file(spec)
    for _, call in ipairs(M.parse_swap_calls(spec_src)) do
      local name = render(title, currencies, accounts, call)
      if name and not seen[name] then
        seen[name] = true
        names[#names + 1] = name
      end
    end
  end
  table.sort(names)
  return names
end

-- Resolve directly from provided source strings + a list of spec contents.
-- Pure sibling of resolve_swap for end-to-end unit tests without disk I/O.
--   sources = { currency=, account=, helper=, specs={ str, str, … } }
function M.resolve_swap_from_sources(sources)
  sources = sources or {}
  local currencies = M.parse_currencies(sources.currency)
  local accounts = M.parse_accounts(sources.account)
  local title = M.parse_swap_title(sources.helper)
  if not title then
    return {}
  end
  local seen, names = {}, {}
  for _, spec_src in ipairs(sources.specs or {}) do
    for _, call in ipairs(M.parse_swap_calls(spec_src)) do
      local name = render(title, currencies, accounts, call)
      if name and not seen[name] then
        seen[name] = true
        names[#names + 1] = name
      end
    end
  end
  table.sort(names)
  return names
end

return M
