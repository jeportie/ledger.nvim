-- Tests for ledger.builder.testnames (POC swap-name resolver, issue #51).
--
-- The bulk are UNIT tests with tiny INLINE fixture strings so they run on CI
-- runners that do NOT have the ledger-live monorepo checked out. A single
-- MONOREPO-integration test runs the resolver against a real checkout when one
-- is present (LEDGER_LIVE_ROOT or the known local path) and otherwise pending()s.

local tn = require("ledger.builder.testnames")

describe("ledger.builder.testnames", function()
  -- ── enum evaluator: currencies ──────────────────────────────────────────
  describe("parse_currencies", function()
    it("captures name + ticker from a single-line declaration", function()
      local cur = tn.parse_currencies([[
        static readonly BTC = new Currency("Bitcoin", "BTC", "bitcoin", AppInfos.BITCOIN, [Network.BITCOIN]);
      ]])
      assert.equals("Bitcoin", cur.name.BTC)
      assert.equals("BTC", cur.ticker.BTC)
    end)

    it("captures name from a multi-line declaration", function()
      local cur = tn.parse_currencies([[
        static readonly ETH = new Currency(
          "Ethereum",
          "ETH",
          "ethereum",
          AppInfos.ETHEREUM,
          [Network.ETHEREUM],
          "0xeeee",
        );
      ]])
      assert.equals("Ethereum", cur.name.ETH)
      assert.equals("ETH", cur.ticker.ETH)
    end)

    it("handles multi-word display names (token currencies)", function()
      local cur = tn.parse_currencies([[
        static readonly ETH_USDC = new Currency("USD Coin", "USDC", "eth/erc20/usdc", AppInfos.ETHEREUM, [Network.ETHEREUM]);
        static readonly ETH_USDT = new Currency("Tether USD", "USDT", "eth/erc20/usdt", AppInfos.ETHEREUM, [Network.ETHEREUM]);
      ]])
      assert.equals("USD Coin", cur.name.ETH_USDC)
      assert.equals("Tether USD", cur.name.ETH_USDT)
    end)

    it("returns empty maps for non-string / empty input", function()
      assert.same({ name = {}, ticker = {} }, tn.parse_currencies(nil))
      assert.same({ name = {}, ticker = {} }, tn.parse_currencies(""))
    end)
  end)

  -- ── enum evaluator: accounts ────────────────────────────────────────────
  describe("parse_accounts", function()
    it("maps a plain Account to its Currency symbol", function()
      local acc = tn.parse_accounts([[
        static readonly ETH_1 = new Account(Currency.ETH, "Ethereum 1", 0, "44'/60'/0'/0/0", undefined, undefined, undefined);
      ]])
      assert.equals("ETH", acc.ETH_1)
    end)

    it("maps a TokenAccount to its Currency symbol (same first arg)", function()
      local acc = tn.parse_accounts([[
        static readonly ETH_USDC_1 = new TokenAccount(
          Currency.ETH_USDC,
          "USD Coin 1",
          0,
          Account.ETH_1.accountPath,
          TokenType.ERC20,
          Account.ETH_1,
        );
      ]])
      assert.equals("ETH_USDC", acc.ETH_USDC_1)
    end)

    it("parses plain and token accounts together", function()
      local acc = tn.parse_accounts([[
        static readonly BTC_NATIVE_SEGWIT_1 = new Account(Currency.BTC, "Bitcoin 1", 0, "84'/0'/0'/0/3", undefined, undefined, "native_segwit");
        static readonly ETH_USDT_1 = new TokenAccount(Currency.ETH_USDT, "Tether USD 1", 0, "p", TokenType.ERC20, Account.ETH_1);
      ]])
      assert.equals("BTC", acc.BTC_NATIVE_SEGWIT_1)
      assert.equals("ETH_USDT", acc.ETH_USDT_1)
    end)

    it("returns an empty map for non-string / empty input", function()
      assert.same({}, tn.parse_accounts(nil))
      assert.same({}, tn.parse_accounts(""))
    end)
  end)

  -- ── account → display name resolution (the enum join) ────────────────────
  describe("account_name", function()
    it("resolves Account.ETH_1 → Ethereum via the currency map", function()
      local cur = tn.parse_currencies('static readonly ETH = new Currency("Ethereum", "ETH", "e", A, []);')
      local acc = tn.parse_accounts('static readonly ETH_1 = new Account(Currency.ETH, "Ethereum 1", 0, "p");')
      assert.equals("Ethereum", tn.account_name("ETH_1", cur, acc))
    end)

    it("returns nil for an unknown account or a currency with no name", function()
      local cur = tn.parse_currencies("")
      local acc = tn.parse_accounts("")
      assert.is_nil(tn.account_name("NOPE_1", cur, acc))
    end)
  end)

  -- ── swap helper title template ──────────────────────────────────────────
  describe("parse_swap_title", function()
    it("extracts the template + ordered params from the it(`…`) title", function()
      local t = tn.parse_swap_title([[
        it(`Swap ${accountToDebit.currency.name} to ${accountToCredit.currency.name}`, async () => {
      ]])
      assert.equals("Swap %s to %s", t.template)
      assert.same({ "accountToDebit", "accountToCredit" }, t.params)
    end)

    it("bails (nil) on an interpolation that is not <ident>.currency.name", function()
      -- e.g. a ternary or a different property — we refuse to half-resolve.
      assert.is_nil(tn.parse_swap_title("it(`Swap ${a.currency.name} to ${cond ? x : y}`, () => {"))
      assert.is_nil(tn.parse_swap_title("it(`Swap ${a.currency.ticker} to ${b.currency.name}`, () => {"))
    end)

    it("returns nil when there is no Swap title", function()
      assert.is_nil(tn.parse_swap_title("it(`Send ${x} tokens`, () => {"))
      assert.is_nil(tn.parse_swap_title(nil))
    end)
  end)

  -- ── Shape-A caller parsing ──────────────────────────────────────────────
  describe("parse_swap_calls", function()
    it("pulls the first two account args of runSwapTest", function()
      local calls = tn.parse_swap_calls([[
        runSwapTest(
          Account.ETH_1,
          Account.BTC_NATIVE_SEGWIT_1,
          ["B2CQA-2750"],
          ["@NanoX", "@ethereum"],
        );
      ]])
      assert.same({ { debit = "ETH_1", credit = "BTC_NATIVE_SEGWIT_1" } }, calls)
    end)

    it("accepts TokenAccount in either position", function()
      local calls = tn.parse_swap_calls([[
        runSwapTest(TokenAccount.ETH_USDC_1, Account.BTC_NATIVE_SEGWIT_1, ["x"], ["y"]);
      ]])
      assert.same({ { debit = "ETH_USDC_1", credit = "BTC_NATIVE_SEGWIT_1" } }, calls)
    end)

    it("ignores tmsLinks/tags/fee and returns [] when no call is present", function()
      assert.same({}, tn.parse_swap_calls("import { runSwapTest } from './swap';"))
    end)
  end)

  -- ── full mini end-to-end (pure, no disk) ────────────────────────────────
  describe("resolve_swap_from_sources", function()
    local currency = [[
      static readonly BTC = new Currency("Bitcoin", "BTC", "bitcoin", A, [N.BTC]);
      static readonly ETH = new Currency(
        "Ethereum",
        "ETH",
        "ethereum",
        A,
        [N.ETH],
      );
    ]]
    local account = [[
      static readonly BTC_NATIVE_SEGWIT_1 = new Account(Currency.BTC, "Bitcoin 1", 0, "p", undefined, undefined, "native_segwit");
      static readonly ETH_1 = new Account(Currency.ETH, "Ethereum 1", 0, "p", undefined, undefined, undefined);
    ]]
    local helper = "it(`Swap ${accountToDebit.currency.name} to ${accountToCredit.currency.name}`, async () => {"

    it("resolves two fake specs into concrete, sorted swap names", function()
      local names = tn.resolve_swap_from_sources({
        currency = currency,
        account = account,
        helper = helper,
        specs = {
          "runSwapTest(Account.ETH_1, Account.BTC_NATIVE_SEGWIT_1, [], []);",
          "runSwapTest(Account.BTC_NATIVE_SEGWIT_1, Account.ETH_1, [], []);",
        },
      })
      assert.same({ "Swap Bitcoin to Ethereum", "Swap Ethereum to Bitcoin" }, names)
    end)

    it("de-duplicates identical resolved names across specs", function()
      local names = tn.resolve_swap_from_sources({
        currency = currency,
        account = account,
        helper = helper,
        specs = {
          "runSwapTest(Account.ETH_1, Account.BTC_NATIVE_SEGWIT_1, [], []);",
          "runSwapTest(Account.ETH_1, Account.BTC_NATIVE_SEGWIT_1, [], []);",
        },
      })
      assert.same({ "Swap Ethereum to Bitcoin" }, names)
    end)

    it("skips a call whose account has no currency mapping (no half-name)", function()
      local names = tn.resolve_swap_from_sources({
        currency = currency,
        account = account,
        helper = helper,
        specs = { "runSwapTest(Account.ETH_1, Account.UNKNOWN_9, [], []);" },
      })
      assert.same({}, names)
    end)

    it("coverage: no resolved name contains a residual '${'", function()
      local names = tn.resolve_swap_from_sources({
        currency = currency,
        account = account,
        helper = helper,
        specs = { "runSwapTest(Account.ETH_1, Account.BTC_NATIVE_SEGWIT_1, [], []);" },
      })
      assert.is_true(#names > 0)
      for _, n in ipairs(names) do
        assert.is_nil(n:find("${", 1, true), "residual template var in: " .. n)
      end
    end)
  end)

  -- ── monorepo integration (skips cleanly without a checkout) ──────────────
  describe("resolve_swap (monorepo)", function()
    -- Prefer an explicit override; else fall back to the known local checkout.
    local ROOT = os.getenv("LEDGER_LIVE_ROOT")
    if not ROOT or ROOT == "" then
      ROOT = vim.fn.expand("~/src/tries/2026-04-08-LedgerHQ-ledger-live")
    end
    local enum_dir = ROOT .. "/libs/ledger-live-common/src/e2e/enum"
    local have_monorepo = vim.fn.isdirectory(ROOT) == 1
      and vim.fn.filereadable(enum_dir .. "/Currency.ts") == 1
      and vim.fn.filereadable(enum_dir .. "/Account.ts") == 1
      and vim.fn.isdirectory(ROOT .. "/e2e/mobile/specs/swap") == 1

    it("resolves every swap spec to a concrete name (or skips w/o monorepo)", function()
      if not have_monorepo then
        pending("monorepo not present at " .. ROOT .. " (set LEDGER_LIVE_ROOT)")
        return
      end
      local names = tn.resolve_swap(ROOT)
      assert.is_true(#names >= 15, "expected a reasonable number of swap names, got " .. #names)
      for _, n in ipairs(names) do
        assert.is_truthy(n:match("^Swap .+ to .+$"), "malformed swap name: " .. n)
        -- coverage metric: 0 titles may retain an unresolved template var.
        assert.is_nil(n:find("${", 1, true), "residual template var in: " .. n)
      end
    end)

    it("resolved names all appear in the CI golden fixture (or skips)", function()
      if not have_monorepo then
        pending("monorepo not present at " .. ROOT)
        return
      end
      -- fixtures/ci_swap_golden.txt lives next to this spec file.
      local here = debug.getinfo(1, "S").source:sub(2)
      local dir = vim.fn.fnamemodify(here, ":h")
      local golden = {}
      for _, line in ipairs(vim.fn.readfile(dir .. "/fixtures/ci_swap_golden.txt")) do
        if line ~= "" then
          golden[line] = true
        end
      end
      local names = tn.resolve_swap(ROOT)
      -- Every locally-resolved name should be in the CI golden set. (This holds
      -- for the 2026-04-08 checkout vs. the 2026-06-30 CI run; a future drift
      -- would surface here and is expected to be explained, not hard-failed in
      -- CI — this assertion only runs locally where the monorepo exists.)
      for _, n in ipairs(names) do
        assert.is_true(golden[n] == true, "resolved name not in CI golden set: " .. n)
      end
    end)
  end)
end)
