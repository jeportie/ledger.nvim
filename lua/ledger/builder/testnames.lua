-- ledger.builder.testnames
--
-- POC (issues #51 + #57). Statically resolves the Builder's "run test by name"
-- template-literal titles into concrete jest/Playwright test names.
--
-- The Builder's picker (see builder/init.lua `pick_test_name`) scrapes titles
-- with a regex and passes them verbatim to `-t`/`--grep`. For parameterized
-- suites the title is a template literal, so the picker offers a name with a
-- literal `${…}` that never matches a run. Two shapes are resolved:
--
--   Shape-A (mobile, issue #51) — `runSwapTest(debit, credit, …)` callers, e.g.
--   in e2e/mobile/specs/swap/swap.ts:
--     it(`Swap ${accountToDebit.currency.name} to ${accountToCredit.currency.name}`, …)
--   → "Swap Bitcoin to Ethereum". See `resolve_swap`.
--
--   Shape-B (desktop, issue #57) — a static array literal + a `for` loop + a
--   parameterized `test.describe`/`test(\`…${x.prop}\`)` title, e.g. in
--   e2e/desktop/tests/specs/{provider.swap,add.account}.spec.ts:
--     for (const { provider } of providerFlowTests)
--       test.describe(`Swap - ${provider.uiName} flow`, …)   → "Swap - 1inch flow"
--     for (const currency of currencies)
--       test(`[${currency.currency.name}] Add account`, …)   → "[Bitcoin] Add account"
--   → See `resolve_desktop`.
--
--   Shape-C (mobile earn/stake, e2e/mobile/specs/earn) — a `const testConfig =
--   { account: Account.X, provider: EarnProvider.Y, … }` object + a
--   `run*Test(testConfig.account, testConfig.provider.name, …)` call whose it()
--   title lives in the helper (earnV2.ts):
--     it(`${account.currency.ticker} earn CTA -> ${providerId} provider -> dapp`)
--   → "ETH earn CTA -> kiln_pooling provider -> dapp". See `resolve_earn`.
--
-- All three resolve by evaluating the e2e enums statically (Account.ETH_1 →
-- Currency.ETH → "Ethereum"; SwapProvider.ONE_INCH → uiName "1inch";
-- Currency.NEAR → speculosApp AppInfos.NEAR → "Near"). Everything is a PURE
-- function of file contents (or a root read once), so the parsers are
-- unit-testable with tiny inline fixtures — the CI runners do NOT have the
-- monorepo checked out.
--
-- Deferred: the `new Delegate(…)` model wrapper + the ternary it() in the two
-- mobile stake guards (changeValidator / stopDelegation); validation.swap.spec.ts
-- (RegExp interpolation); the ternary title in the swap body (XRP amount branch).

local uv = vim.uv or vim.loop

local M = {}

-- ── low-level helpers ──────────────────────────────────────────────────────

-- Drop whole-line `//` comments (lines whose first non-space char is `//`) so a
-- commented-out array element — e.g. the disabled `// { currency: Currency.TON,
-- … }` in add.account.spec.ts — is not scraped as a live entry. We only strip
-- FULL comment lines, never inline `//`, to avoid touching a `//` that might sit
-- inside a string/template literal on a code line. Returns the source unchanged
-- when given a non-string.
local function strip_line_comments(src)
  if type(src) ~= "string" then
    return src
  end
  local kept = {}
  for line in (src .. "\n"):gmatch("(.-)\n") do
    if not line:match("^%s*//") then
      kept[#kept + 1] = line
    end
  end
  return table.concat(kept, "\n")
end

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

-- ── DESKTOP "Shape-B": array literal → for-loop → parameterized title ───────
--
-- Desktop specs (issue #57, milestone 1) parameterize differently from the
-- mobile Shape-A helper. Instead of `runSwapTest(a, b, …)` calls they declare a
-- static array of object literals and loop over it, building the Playwright
-- title from a field of each element. Two pure shapes are covered:
--
--   e2e/desktop/tests/specs/provider.swap.spec.ts
--     const providerFlowTests = [
--       { fromAccount: …, provider: SwapProvider.ONE_INCH, … },
--       { …,             provider: SwapProvider.OKX,       … },
--     ];
--     for (const { fromAccount, toAccount, provider, … } of providerFlowTests) {
--       test.describe(`Swap - ${provider.uiName} flow`, …)   // → "Swap - 1inch flow"
--
--   e2e/desktop/tests/specs/add.account.spec.ts
--     const currencies = [ { currency: Currency.BTC, … }, … Currency.ZEC ];
--     for (const currency of currencies) {
--       test(`[${currency.currency.name}] Add account`, …)   // → "[Bitcoin] Add account"
--     }
--     // plus a direct-literal title outside the loop:
--     test(`[${Currency.ALEO.name}] Add account`, …)         // → "[Aleo] Add account"
--
-- Everything is a PURE function of file contents, unit-testable with inline
-- fixtures. The enum evaluators reuse `parse_currencies`/`parse_accounts`; a new
-- `parse_providers` covers `SwapProvider`/`EarnProvider`. Only the exact accessor
-- written in the template is honored (swap uses `.uiName`, earn uses `.name`), so
-- we never emit a name resolved against the wrong property.

-- Enum-class names whose `Class.SYM` references we recognise inside array object
-- literals and direct-literal titles. Value = the map "family" used to resolve a
-- leaf accessor against the parsed enum tables (see `resolve_enum_leaf`).
local ENUM_CLASSES = {
  Currency = "currency",
  Account = "account",
  TokenAccount = "account",
  SwapProvider = "provider",
  EarnProvider = "provider",
  BuySellProvider = "provider",
}

-- Parse provider enums (`SwapProvider`/`EarnProvider`/`BuySellProvider`) →
--   { name = { SYM = "<name>" }, uiName = { SYM = "<uiName>" } }
-- Every provider's first two ctor string literals are (name, uiName) — the base
-- ctor is `(name, uiName)` and the subclasses pass extra flags AFTER those two.
-- We anchor on `= new <Provider>(` and capture the first two double-quoted
-- literals, exactly like `parse_currencies`. So SwapProvider.ONE_INCH →
-- name="oneinch", uiName="1inch"; EarnProvider.LIDO → name="lido", uiName="Lido".
function M.parse_providers(src)
  local name, uiName = {}, {}
  if type(src) ~= "string" then
    return { name = name, uiName = uiName }
  end
  local ctor = "readonly%s+([%w_]+)%s*=%s*new%s+%w*Provider%((.-)%)%s*;"
  for sym, args in src:gmatch(ctor) do
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
      uiName[sym] = lits[2]
    end
  end
  return { name = name, uiName = uiName }
end

-- Parse `AppInfos.ts` → { SYM = "Display Name" }. Each entry is
--   static readonly ETHEREUM = new AppInfos("Ethereum");
-- (the ctor's single string literal is the speculos-app display name). Used to
-- resolve `currency.speculosApp.name` in the mobile-earn inline-add-account title.
function M.parse_appinfos(src)
  local names = {}
  if type(src) ~= "string" then
    return names
  end
  for sym, nm in src:gmatch('readonly%s+([%w_]+)%s*=%s*new%s+AppInfos%(%s*"([^"]*)"') do
    names[sym] = nm
  end
  return names
end

-- Parse `Currency.ts` → { SYM = "APPINFOS_SYM" }: each currency's 4th ctor arg is
-- its `speculosApp` (an `AppInfos.<SYM>` reference), e.g.
--   new Currency("NEAR", "NEAR", "near", AppInfos.NEAR, …) → { NEAR = "NEAR" }.
-- Kept SEPARATE from parse_currencies (which only captures name/ticker) so the
-- shipped swap/desktop resolvers are untouched; the mobile-earn resolver bundles
-- this + parse_appinfos to walk currency → speculosApp → name.
function M.parse_currency_speculos(src)
  local speculos = {}
  if type(src) ~= "string" then
    return speculos
  end
  for sym, args in src:gmatch("readonly%s+([%w_]+)%s*=%s*new%s+Currency%((.-)%)%s*;") do
    local app = args:match("AppInfos%.([%w_]+)")
    if app then
      speculos[sym] = app
    end
  end
  return speculos
end

-- An "enums" bundle groups every parsed enum family so a single accessor
-- resolver can walk any `Class.SYM.leaf` chain. `accounts` join through
-- currencies (an account has no display name of its own).
--   enums = { currencies = <parse_currencies>, accounts = <parse_accounts>,
--             providers = <parse_providers> }

-- Resolve a leaf accessor against an enum reference. `class` is the JS class
-- name (e.g. "Currency"), `sym` the member (e.g. "BTC"), `leaf` the trailing
-- property (e.g. "name"/"ticker"/"uiName"). Returns the concrete string or nil.
local function resolve_enum_leaf(enums, class, sym, leaf)
  local family = ENUM_CLASSES[class]
  if family == "currency" then
    local c = enums.currencies or {}
    if leaf == "name" then
      return c.name and c.name[sym]
    elseif leaf == "ticker" then
      return c.ticker and c.ticker[sym]
    end
  elseif family == "account" then
    -- Accounts expose `.currency.<leaf>`: the account's currency symbol joined
    -- through the currency table. The caller passes the post-account leaf, so a
    -- template `${x.currency.name}` where x is an Account arrives here as
    -- class="Account", leaf handled one level up (see resolve_accessor).
    local cur = enums.accounts and enums.accounts[sym]
    if not cur then
      return nil
    end
    return resolve_enum_leaf(enums, "Currency", cur, leaf)
  elseif family == "provider" then
    local p = enums.providers or {}
    if leaf == "uiName" then
      return p.uiName and p.uiName[sym]
    elseif leaf == "name" then
      return p.name and p.name[sym]
    end
  end
  return nil
end

-- Parse a `const NAME = [ … ];` array of OBJECT LITERALS whose fields hold enum
-- refs. Returns `name, elements` where `elements` is an ordered list of
-- `{ field = { class=, sym= }, … }` maps (only enum-ref fields are kept; string
-- fields like xrayTicket are ignored). Returns nil if `array_name` isn't found.
-- `array_name` may be nil to grab the FIRST top-level `const … = [ … ]`.
function M.parse_object_array(src, array_name)
  if type(src) ~= "string" then
    return nil
  end
  -- Allow an optional TypeScript annotation between the name and `=`, e.g.
  -- `const currencies: AddAccountTestCase[] = [...]` or `const a: Array<{…}> = [...]`.
  -- `%f[^%w_]` pins the end of the array name (so a lookup for `swapMax` won't
  -- match `swapMaxBalancePairs`), then `[^=]*` consumes the `: Type ` before `=`.
  local pat = array_name and ("const%s+" .. array_name .. "%f[^%w_][^=]*=%s*%[(.-)%]%s*;")
    or "const%s+[%w_]+[^=]*=%s*%[(.-)%]%s*;"
  local body = src:match(pat)
  if not body then
    return nil, {}
  end
  local elements = {}
  -- Two element forms:
  --   * object literal `{ field: Class.SYM, … }` — one element per top-level `{…}`.
  --   * BARE enum ref `Class.SYM` — a whole element that IS the ref (e.g.
  --     `const dexProviders = [SwapProvider.ONE_INCH, …]`). Stored under the
  --     `__self` sentinel so resolve_accessor can treat the loop var as the ref.
  -- Object literals here don't nest braces, so a non-greedy `{(.-)}` captures one
  -- element's fields at a time; bare refs are matched only OUTSIDE those braces.
  local brace_body = {}
  for obj in body:gmatch("{(.-)}") do
    brace_body[#brace_body + 1] = obj
    local fields = {}
    for key, class, sym in obj:gmatch("([%w_]+)%s*:%s*([%w_]+)%.([%w_]+)") do
      if ENUM_CLASSES[class] then
        fields[key] = { class = class, sym = sym }
      end
    end
    if next(fields) then
      elements[#elements + 1] = fields
    end
  end
  -- Bare refs: scan the body with the object literals stripped out, so a
  -- `field: Class.SYM` inside a `{…}` isn't double-counted as a bare element.
  if #brace_body == 0 then
    for class, sym in body:gmatch("([%w_]+)%.([%w_]+)") do
      if ENUM_CLASSES[class] then
        elements[#elements + 1] = { __self = { class = class, sym = sym } }
      end
    end
  end
  return array_name or true, elements
end

-- Split ONE parameterized title into `{ template, accessors }`, or nil if any
-- interpolation isn't a resolvable `head.path` chain (a ternary, a bare ident,
-- etc.). `template` has each `${…}` replaced by `%s`; `accessors` lists, per
-- slot, the split accessor (head = first identifier, path = the remaining dotted
-- segments). Shared by every title form so the resolver treats them uniformly.
-- `min_segs` (default 2) is the fewest segments an interpolation must have; the
-- mobile-earn helper titles pass 1 to allow a bare `${param}` (e.g. `${providerId}`)
-- that binds to a call arg elsewhere.
local function split_title(raw, min_segs)
  min_segs = min_segs or 2
  local accessors = {}
  local ok = true
  local template = raw:gsub("%${([^}]*)}", function(expr)
    local chain = expr:match("^%s*([%w_%.]+)%s*$")
    if not chain then
      ok = false
      return "${" .. expr .. "}"
    end
    local segs = {}
    for s in chain:gmatch("[%w_]+") do
      segs[#segs + 1] = s
    end
    if #segs < min_segs then
      ok = false
      return "${" .. expr .. "}"
    end
    accessors[#accessors + 1] = { head = segs[1], path = { unpack(segs, 2) } }
    return "\0"
  end)
  if not ok then
    return nil
  end
  template = template:gsub("%%", "%%%%"):gsub("%z", "%%s")
  return { template = template, accessors = accessors }
end

-- Parse the `for (const <binding> of NAME) { … }` header that iterates an array,
-- plus EVERY parameterized title inside its body. Returns
--   { array = "NAME", binding = { kind = "destructure"|"ident",
--                                 fields = { "provider", … } | var = "currency" },
--     titles = { { template = "Swap - %s flow", accessors = { {head=,path=} } }, … } }
-- with one `titles` entry per parameterized `test.describe(\`…\`)`/`test(\`…\`)`
-- template found in this loop's body, in source order. Returns nil if no such
-- loop is found or the body has no resolvable parameterized title.
--
-- The body is scoped from THIS loop's header to the next `for (const …` (or end
-- of source), so a spec with several loops (e.g. earn's cold-start / active /
-- provider loops) attributes each title to the right array. Both title forms are
-- captured because a loop may wrap its parameterized `test.describe` around an
-- equally parameterized inner `test` whose title DIFFERS (earn) — CI records the
-- `test()` leaf, so both must be emitted. A title with no `${…}` (a plain-string
-- describe/test) is skipped; a title whose interpolation we can't statically
-- resolve is skipped too (never a half-resolved name). Direct-literal titles
-- (`${Class.SYM.leaf}`) outside any loop are handled in resolve_shape_b.
function M.parse_loop_title(src, array_name)
  if type(src) ~= "string" then
    return nil
  end
  -- Loop header: `for (const <binding> of <NAME>)`. Binding is either
  -- `{ a, b, c }` or a bare identifier. Track the byte offset so the body can be
  -- sliced from THIS loop rather than the first `for` in the file.
  local binding_src, arr, header_end
  local pos = 1
  while true do
    local s, e, b, a = src:find("for%s*%(%s*const%s+(.-)%s+of%s+([%w_]+)%s*%)", pos)
    if not s then
      break
    end
    if not array_name or a == array_name then
      binding_src, arr, header_end = b, a, e
      break
    end
    pos = e + 1
  end
  if not binding_src then
    return nil
  end

  local binding
  local destructured = binding_src:match("^%s*{%s*(.-)%s*}%s*$")
  if destructured then
    local fields = {}
    for f in destructured:gmatch("[%w_]+") do
      fields[#fields + 1] = f
    end
    binding = { kind = "destructure", fields = fields }
  else
    local ident = binding_src:match("^%s*([%w_]+)%s*$")
    if not ident then
      return nil
    end
    binding = { kind = "ident", var = ident }
  end

  -- Scope the body to this loop: from just past its header up to the next
  -- `for (const …` (or end of source).
  local next_for = src:find("for%s*%(%s*const", header_end + 1)
  local body = src:sub(header_end + 1, next_for and next_for - 1 or #src)

  -- Collect every parameterized title in the body, in source order. Both
  -- `test.describe(\`…\`)` and `test(\`…\`)` forms; `test%(` cannot match inside
  -- `test.describe(` (there `test` is followed by `.`, not `(`), so the two are
  -- disjoint at the call site. A title is kept only if it interpolates something
  -- (has `${`) and split_title resolves every interpolation.
  local titles = {}
  local matches = {}
  for pos_, raw in body:gmatch("()test%.describe%(%s*`([^`]*)`") do
    matches[#matches + 1] = { at = pos_, raw = raw }
  end
  for pos_, raw in body:gmatch("()test%(%s*`([^`]*)`") do
    matches[#matches + 1] = { at = pos_, raw = raw }
  end
  table.sort(matches, function(x, y)
    return x.at < y.at
  end)
  for _, m in ipairs(matches) do
    if m.raw:find("%${") then
      local title = split_title(m.raw)
      if title then
        titles[#titles + 1] = title
      end
    end
  end
  if #titles == 0 then
    return nil
  end

  return {
    array = arr,
    binding = binding,
    titles = titles,
  }
end

-- Resolve ONE accessor (head + dotted path) for ONE array element to a concrete
-- string. `enums` is the parsed bundle; `binding` describes the loop variable;
-- `element` is a `field → {class,sym}` map. Handles:
--   * destructured loop `{ provider }`, accessor `provider.uiName`:
--       head "provider" is a field → its enum ref; path {"uiName"} = leaf.
--   * plain loop `currency`, accessor `currency.currency.name`:
--       head "currency" == loop var (the element); next "currency" is a field →
--       enum ref; remaining {"name"} = leaf.
--   * direct literal `Currency.ALEO.name` (binding ignored):
--       head "Currency" is a known class; next "ALEO" = sym; remaining = leaf.
local function resolve_accessor(enums, binding, element, acc)
  local head, path = acc.head, acc.path

  -- Direct enum literal: head is a class name (Currency.ALEO.name).
  if ENUM_CLASSES[head] and path[1] then
    local sym = path[1]
    local leaf = path[#path]
    return resolve_enum_leaf(enums, head, sym, leaf)
  end

  -- Bare-ref element (`const arr = [Class.SYM, …]`): the loop var IS the ref, so
  -- `${provider.uiName}` → head is the loop var, path is the leaf chain.
  if binding.kind == "ident" and element and element.__self then
    if head ~= binding.var or not path[1] then
      return nil
    end
    return resolve_enum_leaf(enums, element.__self.class, element.__self.sym, path[#path])
  end

  -- Loop-bound accessor. Determine which field of the element the ref lives in
  -- and what the leaf accessor is.
  local field, leaf
  if binding.kind == "destructure" then
    -- head IS the field (e.g. "provider"); path holds the enum leaf(s).
    field, leaf = head, path[#path]
  else
    -- head must be the loop var (whole element); the FIRST path segment is the
    -- field, and the last is the leaf.
    if head ~= binding.var or not path[1] then
      return nil
    end
    field, leaf = path[1], path[#path]
  end

  local ref = element and element[field]
  if not ref then
    return nil
  end
  return resolve_enum_leaf(enums, ref.class, ref.sym, leaf)
end

-- Emit ONE concrete name into `acc`, de-duplicated on `seen`. Appends to
-- `acc.names` (and `acc.entries` with its owning spec, when the accumulator
-- tracks them). Shared by the loop-driven and direct-literal branches.
local function emit(acc, name, spec)
  if not acc.seen[name] then
    acc.seen[name] = true
    acc.names[#acc.names + 1] = name
    if acc.entries then
      acc.entries[#acc.entries + 1] = { name = name, spec = spec }
    end
  end
end

-- Render every concrete title for a Shape-B (array + loop + template) unit.
-- Appends into `acc` (a { seen=, names= } accumulator) so a caller can fold
-- several specs together. Also resolves any direct-literal titles found in the
-- source (the Aleo add-account case) via the same accessor machinery.
local function resolve_shape_b(enums, src, array_name, acc, spec)
  -- Strip commented-out lines first so a disabled array element (e.g. TON in
  -- add.account.spec.ts) is never scraped as a live test name.
  src = strip_line_comments(src)
  local _, elements = M.parse_object_array(src, array_name)
  local loop = M.parse_loop_title(src, array_name)

  -- 1) Loop-driven titles: for EACH array element, resolve EVERY title in the
  -- loop body. A loop may parameterize both its `test.describe` and a distinct
  -- inner `test` (earn), so both names are emitted per element; a single-title
  -- loop (swap/add.account) yields one name each, and an identical describe+test
  -- pair (were one to exist) collapses via the shared dedup.
  if loop and elements then
    for _, element in ipairs(elements) do
      for _, title in ipairs(loop.titles) do
        local values, complete = {}, true
        for _, a in ipairs(title.accessors) do
          local v = resolve_accessor(enums, loop.binding, element, a)
          if not v then
            complete = false
            break
          end
          values[#values + 1] = v
        end
        if complete then
          emit(acc, string.format(title.template, unpack(values)), spec)
        end
      end
    end
  end

  -- 2) Direct-literal titles: test(`…${Class.SYM.leaf}…`) NOT inside the loop
  -- (e.g. the Aleo add-account block). We scan every backtick title whose
  -- interpolations are ALL direct enum literals; loop-bound titles are skipped
  -- here because their head isn't a known enum class.
  for raw in src:gmatch("test%(%s*`([^`]*)`") do
    if raw:find("%${") then
      local values, all_direct, any = {}, true, false
      local template = raw:gsub("%${([^}]*)}", function(expr)
        any = true
        local chain = expr:match("^%s*([%w_%.]+)%s*$")
        local head = chain and chain:match("^([%w_]+)")
        if not head or not ENUM_CLASSES[head] then
          all_direct = false
          return ""
        end
        local segs = {}
        for s in chain:gmatch("[%w_]+") do
          segs[#segs + 1] = s
        end
        local v = resolve_enum_leaf(enums, segs[1], segs[2], segs[#segs])
        if not v then
          all_direct = false
          return ""
        end
        values[#values + 1] = v
        return "\0"
      end)
      if any and all_direct then
        template = template:gsub("%%", "%%%%"):gsub("%z", "%%s")
        emit(acc, string.format(template, unpack(values)), spec)
      end
    end
  end
end

-- Pure Shape-B end-to-end from source strings (no disk). Mirrors
-- `resolve_swap_from_sources` for unit tests.
--   sources = { currency=, account=, provider=, specs = { { src=, array= }, … } }
-- Each spec entry names its array (or nil for the first `const … = [ … ]`).
function M.resolve_desktop_from_sources(sources)
  sources = sources or {}
  local enums = {
    currencies = M.parse_currencies(sources.currency),
    accounts = M.parse_accounts(sources.account),
    providers = M.parse_providers(sources.provider),
  }
  local acc = { seen = {}, names = {} }
  for _, spec in ipairs(sources.specs or {}) do
    resolve_shape_b(enums, spec.src, spec.array, acc)
  end
  table.sort(acc.names)
  return acc.names
end

-- ── public entry point ─────────────────────────────────────────────────────

-- Default monorepo-relative locations (verified against the 2026-04-08 checkout).
-- The e2e enum tables have moved twice: libs/ledger-live-common/src/e2e →
-- e2e/shared/src/enum → libs/live-e2e-shared/src/enum (LedgerHQ/ledger-live
-- #19312 "move e2e/shared to libs"). Try newest-first, falling back so the
-- resolver works across checkout vintages. The newest entry is inert until that
-- dir exists (first-readable-wins), so this is safe to land before #19312 merges.
local ENUM_DIRS = {
  "libs/live-e2e-shared/src/enum",
  "e2e/shared/src/enum",
  "libs/ledger-live-common/src/e2e/enum",
}
local SWAP_DIR = "e2e/mobile/specs/swap"
local MOBILE_EARN_DIR = "e2e/mobile/specs/earn"

-- First enum dir whose Currency.ts is readable (else the new-path default, whose
-- upstream read then fails → {}). `_`-exposed for unit tests.
function M._detect_enum_dir(root)
  for _, rel in ipairs(ENUM_DIRS) do
    local dir = root .. "/" .. rel
    if vim.fn.filereadable(dir .. "/Currency.ts") == 1 then
      return dir
    end
  end
  return root .. "/" .. ENUM_DIRS[1]
end

-- Desktop Shape-B (issues #57 + #58). Scoped to explicitly-vetted (spec, array)
-- pairs — each entry names the spec file (relative to the desktop specs dir) and
-- the array variable the resolver's loop iterates. Kept explicit rather than
-- globbing so the output is exactly the validated golden set; broadening to more
-- specs is a follow-up.
--
-- earn.v2.spec.ts contributes three arrays: each of its loops wraps a
-- parameterized `test.describe` around a DISTINCT parameterized inner `test`, so
-- the multi-title parse_loop_title emits both the describe title and the `test()`
-- leaf CI records (accessors `.currency.ticker` and `provider.name`).
local DESKTOP_SPEC_DIR = "e2e/desktop/tests/specs"
local DESKTOP_SHAPE_B = {
  { spec = "provider.swap.spec.ts", array = "providerFlowTests" },
  { spec = "add.account.spec.ts", array = "currencies" },
  { spec = "earn.v2.spec.ts", array = "coldStartCurrencies" },
  { spec = "earn.v2.spec.ts", array = "activePositionCurrencies" },
  { spec = "earn.v2.spec.ts", array = "ethProviders" },
  -- currency-pair swap loops + the receive loop (all clean Shape-B: static array
  -- of {…} + `for (const … of NAME)` + `${…currency.name}` title).
  { spec = "send.swap.spec.ts", array = "swaps" }, -- Swap <from> to <to>
  { spec = "entrypoint.swap.spec.ts", array = "swapMax" }, -- Swap max amount from <from> to <to>
  { spec = "receive.address.spec.ts", array = "nativeAccounts" }, -- [<currency>] Receive
  -- bare enum-ref array (elements are `SwapProvider.X`, not `{…}`).
  { spec = "crossAccount.warning.swap.spec.ts", array = "dexProviders" }, -- …swap with <uiName>
}

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
  local enum_dir = opts.enum_dir or M._detect_enum_dir(root)
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

-- Resolve every DESKTOP Shape-B test name from a monorepo checkout at `root`.
-- Returns a SORTED, de-duplicated list of concrete names for the M1-scoped specs
-- (see DESKTOP_SHAPE_B). Reads the shared enum tables once, then folds each spec.
-- `opts` (optional): { enum_dir=, spec_dir=, currency_file=, account_file=,
--   provider_file=, specs= } to override paths/scope (used by tests / future
--   callers). Returns {} on any missing input, so an empty result means
--   "monorepo unavailable".
function M.resolve_desktop(root, opts)
  opts = opts or {}
  if type(root) ~= "string" or root == "" then
    return {}
  end
  local enum_dir = opts.enum_dir or M._detect_enum_dir(root)
  local spec_dir = opts.spec_dir or (root .. "/" .. DESKTOP_SPEC_DIR)

  local currency_src = read_file(opts.currency_file or (enum_dir .. "/Currency.ts"))
  local account_src = read_file(opts.account_file or (enum_dir .. "/Account.ts"))
  local provider_src = read_file(opts.provider_file or (enum_dir .. "/Provider.ts"))
  if not currency_src or not account_src or not provider_src then
    return {}
  end

  local enums = {
    currencies = M.parse_currencies(currency_src),
    accounts = M.parse_accounts(account_src),
    providers = M.parse_providers(provider_src),
  }

  local acc = { seen = {}, names = {} }
  for _, entry in ipairs(opts.specs or DESKTOP_SHAPE_B) do
    local spec_src = read_file(spec_dir .. "/" .. entry.spec)
    if spec_src then
      resolve_shape_b(enums, spec_src, entry.array, acc)
    end
  end
  table.sort(acc.names)
  return acc.names
end

-- ── MOBILE "Shape-C": testConfig object literal + earnV2 helper titles ──────
--
-- Mobile earn/stake (e2e/mobile/specs/earn) parameterizes a THIRD way. Each spec
-- declares one object literal and calls a helper with its fields:
--   const testConfig = { account: Account.ETH_1, provider: EarnProvider.KILN, … };
--   runPartnerDappCTATest(testConfig.account, testConfig.provider.name, …);
-- and the it() title lives in the HELPER (earnV2.ts), e.g.
--   it(`${account.currency.ticker} earn CTA -> ${providerId} provider -> dapp`)
--   → "ETH earn CTA -> kiln_pooling provider -> dapp".
-- Resolution binds each title placeholder (a helper PARAM) to the matching
-- positional call arg (a testConfig field, maybe with a `.name` leaf), reads that
-- field's enum ref from the object, and walks the accessor chain. Unlike swap
-- (direct Account.X args) the args are indirect; unlike desktop the titles come
-- from the helper, not the spec — hence a dedicated resolver.

-- Parse a single `const <name> = { … }` object literal → { field = {class, sym} }
-- for enum-ref fields (string/array fields ignored). `name` may be nil to grab the
-- first `const … = { … }`. Uses a balanced-brace scan (not `{(.-)}`) so a `${…}`
-- inside a string field — e.g. dappUrlSubstring: `…/${Account.X.currency.ticker}`
-- — neither truncates the object nor is scraped as a field ref.
function M.parse_object_literal(src, name)
  if type(src) ~= "string" then
    return nil
  end
  local pat = name and ("const%s+" .. name .. "%s*=%s*{") or "const%s+[%w_]+%s*=%s*{"
  local _, open = src:find(pat)
  if not open then
    return nil
  end
  -- Balance from the opening brace. A `${` adds one `{` and its `}` closes it, so
  -- brace counting stays correct across interpolations.
  local depth, body_start, body_end = 0, nil, nil
  for i = open, #src do
    local c = src:sub(i, i)
    if c == "{" then
      depth = depth + 1
      if depth == 1 then
        body_start = i + 1
      end
    elseif c == "}" then
      depth = depth - 1
      if depth == 0 then
        body_end = i - 1
        break
      end
    end
  end
  if not body_end then
    return nil
  end
  local fields = {}
  for key, class, sym in src:sub(body_start, body_end):gmatch("([%w_]+)%s*:%s*([%w_]+)%.([%w_]+)") do
    if ENUM_CLASSES[class] then
      fields[key] = { class = class, sym = sym }
    end
  end
  return fields
end

-- Parse earnV2.ts → { helperName = { params = { "account", … },
--   it = { template = "…%s…", accessors = { {head=,path=}, … } } } }, one entry
-- per exported `run*Test` whose it() title is PARAMETERIZED. A helper with a
-- static it() (ice-cold-start) is omitted — its title is already picked up by the
-- raw scrape. Each helper's body is sliced from its header to the next
-- `export function` so its it() is attributed correctly.
function M.parse_earn_helpers(src)
  local helpers = {}
  if type(src) ~= "string" then
    return helpers
  end
  local heads = {}
  for at, name, params in src:gmatch("()export%s+function%s+(run[%w_]*Test)%s*%((.-)%)") do
    heads[#heads + 1] = { at = at, name = name, params = params }
  end
  for i, h in ipairs(heads) do
    local body = src:sub(h.at, (heads[i + 1] and heads[i + 1].at - 1) or #src)
    local params = {}
    for p in h.params:gmatch("[^,]+") do
      local id = p:match("^%s*([%w_]+)")
      if id then
        params[#params + 1] = id
      end
    end
    -- First parameterized it(`…`) in the body. Frontier `%f[%w_]` keeps `it` a
    -- whole token (never matches inside `await(`, `wait(`, …).
    local it_title
    for raw in body:gmatch("%f[%w_]it%s*%(%s*`([^`]*)`") do
      if raw:find("%${") then
        it_title = split_title(raw, 1) -- earn titles allow a bare `${param}`
        if it_title then
          break
        end
      end
    end
    if it_title then
      helpers[h.name] = { params = params, it = it_title }
    end
  end
  return helpers
end

-- Parse a spec's `run*Test(testConfig.a, testConfig.b.name, …)` call → { helper=,
-- args = { { field=, leaf= }, … } } in positional order. `leaf` is the arg-side
-- accessor (`name` in testConfig.provider.name), nil when absent. A literal
-- (non-testConfig) arg keeps its slot as {} so param↔arg indices stay aligned.
function M.parse_earn_call(src)
  if type(src) ~= "string" then
    return nil
  end
  local helper, args_str = src:match("(run[%w_]*Test)%s*%((.-)%)")
  if not helper then
    return nil
  end
  local args = {}
  for a in args_str:gmatch("[^,]+") do
    if a:match("%S") then
      local field, leaf = a:match("testConfig%.([%w_]+)%.?([%w_]*)")
      if field then
        args[#args + 1] = { field = field, leaf = (leaf ~= "" and leaf) or nil }
      else
        args[#args + 1] = {}
      end
    end
  end
  return { helper = helper, args = args }
end

-- Walk a property path from an enum ref { class, sym } to a concrete string.
-- Nodes: account (currency → currency ref), currency (name/ticker → string;
-- speculosApp → appinfos ref), appinfos (name → string), provider (name/uiName →
-- string). Returns nil on any unknown/unresolved hop. `enums` bundles currencies,
-- accounts, providers, speculos (currency SYM → appinfos SYM) and appinfos
-- (appinfos SYM → name).
local function earn_walk(enums, class, sym, path)
  local node = { family = ENUM_CLASSES[class], sym = sym }
  for _, seg in ipairs(path) do
    local f = node.family
    if f == "account" then
      if seg ~= "currency" then
        return nil
      end
      local cur = enums.accounts and enums.accounts[node.sym]
      if not cur then
        return nil
      end
      node = { family = "currency", sym = cur }
    elseif f == "currency" then
      local c = enums.currencies or {}
      if seg == "name" then
        return c.name and c.name[node.sym]
      elseif seg == "ticker" then
        return c.ticker and c.ticker[node.sym]
      elseif seg == "speculosApp" then
        local app = enums.speculos and enums.speculos[node.sym]
        if not app then
          return nil
        end
        node = { family = "appinfos", sym = app }
      else
        return nil
      end
    elseif f == "appinfos" then
      if seg == "name" then
        return enums.appinfos and enums.appinfos[node.sym]
      end
      return nil
    elseif f == "provider" then
      local p = enums.providers or {}
      if seg == "name" then
        return p.name and p.name[node.sym]
      elseif seg == "uiName" then
        return p.uiName and p.uiName[node.sym]
      end
      return nil
    else
      return nil
    end
  end
  return nil -- path did not terminate on a string leaf
end

-- Build the earn enum bundle from source strings (currencies/accounts/providers +
-- the speculos ref map + appinfos names).
local function earn_enums(sources)
  return {
    currencies = M.parse_currencies(sources.currency),
    accounts = M.parse_accounts(sources.account),
    providers = M.parse_providers(sources.provider),
    speculos = M.parse_currency_speculos(sources.currency),
    appinfos = M.parse_appinfos(sources.appinfos),
  }
end

-- Resolve every earn spec into `acc` (a { seen, names[, entries] } accumulator).
-- Per spec: read its testConfig object + the run*Test call, look up the helper's
-- parameterized it() title, bind each placeholder (a param) to its positional call
-- arg, and walk (arg leaf ++ title path) from the field's enum ref. Emits only
-- when EVERY placeholder resolves — never a half-resolved name.
local function earn_resolve_into(acc, enums, helpers, specs)
  for _, spec in ipairs(specs) do
    local src = type(spec) == "table" and spec.src or spec
    local spec_rel = type(spec) == "table" and spec.spec or nil
    local obj = M.parse_object_literal(src)
    local call = M.parse_earn_call(src)
    local helper = call and helpers[call.helper]
    if obj and helper then
      local idx = {}
      for i, p in ipairs(helper.params) do
        idx[p] = i
      end
      local values, complete = {}, true
      for _, a in ipairs(helper.it.accessors) do
        local arg = idx[a.head] and call.args[idx[a.head]]
        local ref = arg and arg.field and obj[arg.field]
        if not ref then
          complete = false
          break
        end
        local path = {}
        if arg.leaf then
          path[#path + 1] = arg.leaf
        end
        for _, seg in ipairs(a.path) do
          path[#path + 1] = seg
        end
        local v = earn_walk(enums, ref.class, ref.sym, path)
        if not v then
          complete = false
          break
        end
        values[#values + 1] = v
      end
      if complete then
        emit(acc, string.format(helper.it.template, unpack(values)), spec_rel)
      end
    end
  end
end

-- Pure Shape-C end-to-end from source strings (no disk). Mirrors
-- resolve_swap_from_sources / resolve_desktop_from_sources.
--   sources = { currency=, account=, provider=, appinfos=, helper=,
--               specs = { { src=, spec= } | <src string>, … } }
function M.resolve_earn_from_sources(sources)
  sources = sources or {}
  local acc = { seen = {}, names = {} }
  earn_resolve_into(acc, earn_enums(sources), M.parse_earn_helpers(sources.helper), sources.specs or {})
  table.sort(acc.names)
  return acc.names
end

-- Same, but returns { { name=, spec= }, … } (unsorted) for the picker.
function M.earn_entries_from_sources(sources)
  sources = sources or {}
  local acc = { seen = {}, names = {}, entries = {} }
  earn_resolve_into(acc, earn_enums(sources), M.parse_earn_helpers(sources.helper), sources.specs or {})
  return acc.entries
end

-- Resolve every mobile-earn test name from a monorepo checkout at `root`. Returns
-- a SORTED, de-duplicated list of concrete it() names, or {} when the monorepo (or
-- a required source) is absent. `opts` (optional): { enum_dir=, earn_dir= }.
function M.resolve_earn(root, opts)
  opts = opts or {}
  if type(root) ~= "string" or root == "" then
    return {}
  end
  local enum_dir = opts.enum_dir or M._detect_enum_dir(root)
  local earn_dir = opts.earn_dir or (root .. "/" .. MOBILE_EARN_DIR)
  local specs = {}
  for _, spec in ipairs(vim.fn.glob(earn_dir .. "/*.spec.ts", true, true)) do
    local s = read_file(spec)
    if s then
      specs[#specs + 1] = { src = s, spec = "specs/earn/" .. vim.fn.fnamemodify(spec, ":t") }
    end
  end
  return M.resolve_earn_from_sources({
    currency = read_file(enum_dir .. "/Currency.ts"),
    account = read_file(enum_dir .. "/Account.ts"),
    provider = read_file(enum_dir .. "/Provider.ts"),
    appinfos = read_file(enum_dir .. "/AppInfos.ts"),
    helper = read_file(earn_dir .. "/earnV2.ts"),
    specs = specs,
  })
end

-- ── run-by-name picker wiring ───────────────────────────────────────────────

-- Concrete names paired with the .spec.ts that runs each, from source strings
-- (no disk). Pure core of `picker_entries` for unit tests. Each `spec` is the
-- path relative to the platform's e2e base (what detox/playwright expect):
--   desktop → sources.specs = { { src=, array=, spec="tests/specs/…" }, … }
--   mobile  → sources = { currency=, account=, helper=, specs={ { src=, spec="specs/…" } } }
-- Returns { { name=, spec= }, … } (unsorted; caller sorts/merges).
function M.picker_entries_from_sources(platform, sources)
  sources = sources or {}
  if platform == "desktop" then
    local enums = {
      currencies = M.parse_currencies(sources.currency),
      accounts = M.parse_accounts(sources.account),
      providers = M.parse_providers(sources.provider),
    }
    local acc = { seen = {}, names = {}, entries = {} }
    for _, spec in ipairs(sources.specs or {}) do
      resolve_shape_b(enums, spec.src, spec.array, acc, spec.spec)
    end
    return acc.entries
  end
  local currencies = M.parse_currencies(sources.currency)
  local accounts = M.parse_accounts(sources.account)
  local title = M.parse_swap_title(sources.helper)
  if not title then
    return {}
  end
  local seen, entries = {}, {}
  for _, spec in ipairs(sources.specs or {}) do
    for _, call in ipairs(M.parse_swap_calls(spec.src)) do
      local name = render(title, currencies, accounts, call)
      if name and not seen[name] then
        seen[name] = true
        entries[#entries + 1] = { name = name, spec = spec.spec }
      end
    end
  end
  return entries
end

-- Concrete { name, spec } pairs for the run-by-name picker, read from a monorepo
-- checkout at `root`. `spec` is relative to the platform's e2e base. Returns {}
-- when the monorepo (or a required source) is absent, so the picker falls back
-- to its raw title scrape.
function M.picker_entries(root, platform)
  if type(root) ~= "string" or root == "" then
    return {}
  end
  local enum_dir = M._detect_enum_dir(root)
  local currency = read_file(enum_dir .. "/Currency.ts")
  local account = read_file(enum_dir .. "/Account.ts")
  if not currency or not account then
    return {}
  end

  if platform == "desktop" then
    local provider = read_file(enum_dir .. "/Provider.ts")
    if not provider then
      return {}
    end
    local spec_dir = root .. "/" .. DESKTOP_SPEC_DIR
    local specs = {}
    for _, entry in ipairs(DESKTOP_SHAPE_B) do
      local src = read_file(spec_dir .. "/" .. entry.spec)
      if src then
        specs[#specs + 1] = { src = src, array = entry.array, spec = "tests/specs/" .. entry.spec }
      end
    end
    return M.picker_entries_from_sources("desktop", {
      currency = currency,
      account = account,
      provider = provider,
      specs = specs,
    })
  end

  -- Mobile: swap (Shape-A) + earn (Shape-C), concatenated. Either family may be
  -- absent (missing helper) while the other still resolves.
  local entries = {}
  local swap_helper = read_file(root .. "/" .. SWAP_DIR .. "/swap.ts")
  if swap_helper then
    local specs = {}
    for _, spec in ipairs(vim.fn.glob(root .. "/" .. SWAP_DIR .. "/*.spec.ts", true, true)) do
      local src = read_file(spec)
      if src then
        specs[#specs + 1] = { src = src, spec = "specs/swap/" .. vim.fn.fnamemodify(spec, ":t") }
      end
    end
    for _, e in
      ipairs(M.picker_entries_from_sources("mobile", {
        currency = currency,
        account = account,
        helper = swap_helper,
        specs = specs,
      }))
    do
      entries[#entries + 1] = e
    end
  end
  local earn_dir = root .. "/" .. MOBILE_EARN_DIR
  local earn_helper = read_file(earn_dir .. "/earnV2.ts")
  if earn_helper then
    local specs = {}
    for _, spec in ipairs(vim.fn.glob(earn_dir .. "/*.spec.ts", true, true)) do
      local src = read_file(spec)
      if src then
        specs[#specs + 1] = { src = src, spec = "specs/earn/" .. vim.fn.fnamemodify(spec, ":t") }
      end
    end
    for _, e in
      ipairs(M.earn_entries_from_sources({
        currency = currency,
        account = account,
        provider = read_file(enum_dir .. "/Provider.ts"),
        appinfos = read_file(enum_dir .. "/AppInfos.ts"),
        helper = earn_helper,
        specs = specs,
      }))
    do
      entries[#entries + 1] = e
    end
  end
  return entries
end

return M
