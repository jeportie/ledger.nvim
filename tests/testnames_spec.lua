-- Tests for ledger.builder.testnames (POC swap-name resolver, issue #51).
--
-- The bulk are UNIT tests with tiny INLINE fixture strings so they run on CI
-- runners that do NOT have the ledger-live monorepo checked out. A single
-- MONOREPO-integration test runs the resolver against a real checkout when one
-- is present (LEDGER_LIVE_ROOT or the known local path) and otherwise pending()s.

local tn = require("ledger.builder.testnames")

describe("ledger.builder.testnames", function()
  -- ── enum dir detection (moved to e2e/shared after the refactor) ─────────
  describe("_detect_enum_dir", function()
    local function mk(rel)
      local root = vim.fn.tempname()
      local dir = root .. "/" .. rel
      vim.fn.mkdir(dir, "p")
      vim.fn.writefile({ "// stub" }, dir .. "/Currency.ts")
      return root
    end
    it("prefers the new e2e/shared/src/enum location", function()
      local root = mk("e2e/shared/src/enum")
      assert.equals(root .. "/e2e/shared/src/enum", tn._detect_enum_dir(root))
    end)
    it("falls back to the old libs/ledger-live-common path", function()
      local root = mk("libs/ledger-live-common/src/e2e/enum")
      assert.equals(root .. "/libs/ledger-live-common/src/e2e/enum", tn._detect_enum_dir(root))
    end)
    it("defaults to the new path when neither exists", function()
      local root = vim.fn.tempname()
      assert.equals(root .. "/e2e/shared/src/enum", tn._detect_enum_dir(root))
    end)
  end)

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

  -- ── picker_entries_from_sources: concrete name ↔ owning spec ─────────────
  describe("picker_entries_from_sources", function()
    it("mobile: pairs each concrete swap name with its spec", function()
      local currency = [[
        static readonly BTC = new Currency("Bitcoin", "BTC", "bitcoin", A, [N.BTC]);
        static readonly ETH = new Currency("Ethereum", "ETH", "ethereum", A, [N.ETH]);
      ]]
      local account = [[
        static readonly BTC_NATIVE_SEGWIT_1 = new Account(Currency.BTC, "Bitcoin 1", 0, "p", undefined, undefined, "native_segwit");
        static readonly ETH_1 = new Account(Currency.ETH, "Ethereum 1", 0, "p", undefined, undefined, undefined);
      ]]
      local helper = "it(`Swap ${accountToDebit.currency.name} to ${accountToCredit.currency.name}`, async () => {"
      local entries = tn.picker_entries_from_sources("mobile", {
        currency = currency,
        account = account,
        helper = helper,
        specs = {
          {
            src = "runSwapTest(Account.ETH_1, Account.BTC_NATIVE_SEGWIT_1, [], []);",
            spec = "specs/swap/ethbtc.spec.ts",
          },
          {
            src = "runSwapTest(Account.BTC_NATIVE_SEGWIT_1, Account.ETH_1, [], []);",
            spec = "specs/swap/btceth.spec.ts",
          },
        },
      })
      assert.same({
        { name = "Swap Ethereum to Bitcoin", spec = "specs/swap/ethbtc.spec.ts" },
        { name = "Swap Bitcoin to Ethereum", spec = "specs/swap/btceth.spec.ts" },
      }, entries)
    end)

    it("desktop: pairs each Shape-B name with its spec", function()
      local entries = tn.picker_entries_from_sources("desktop", {
        currency = [[
          static readonly BTC = new Currency("Bitcoin", "BTC", "bitcoin", A, []);
          static readonly ETH = new Currency("Ethereum", "ETH", "ethereum", A, []);
        ]],
        specs = {
          {
            array = "currencies",
            spec = "tests/specs/add.account.spec.ts",
            src = [[
              const currencies = [
                { currency: Currency.BTC, xrayTicket: "X" },
                { currency: Currency.ETH, xrayTicket: "Y" },
              ];
              for (const currency of currencies) {
                test(`[${currency.currency.name}] Add account`, () => {});
              }
            ]],
          },
        },
      })
      assert.same({
        { name = "[Bitcoin] Add account", spec = "tests/specs/add.account.spec.ts" },
        { name = "[Ethereum] Add account", spec = "tests/specs/add.account.spec.ts" },
      }, entries)
    end)
  end)

  -- ══ DESKTOP "Shape-B": array literal → for-loop → parameterized title ═════
  --
  -- All unit tests use tiny INLINE fixtures (CI has no monorepo). A single
  -- integration test at the bottom validates against a real checkout / the
  -- 19-name CI golden fixture and pending()s otherwise.

  -- ── provider enum evaluator ─────────────────────────────────────────────
  describe("parse_providers", function()
    it("captures name + uiName from a SwapProvider (extra ctor flags after)", function()
      -- SwapProvider ctor is (name, uiName, kyc, availableOnLns, addr?, app?) —
      -- only the first two string literals are name/uiName.
      local p = tn.parse_providers([[
        static readonly ONE_INCH = new SwapProvider(
          "oneinch", "1inch", false, true, "0x1111", AppInfos.ONE_INCH);
        static readonly OKX = new SwapProvider("okx", "OKX", false, false, "0x40aa", AppInfos.ETHEREUM);
      ]])
      assert.equals("oneinch", p.name.ONE_INCH)
      assert.equals("1inch", p.uiName.ONE_INCH)
      assert.equals("OKX", p.uiName.OKX)
    end)

    it("captures an EarnProvider declared with the 2-arg base ctor", function()
      local p = tn.parse_providers([[
        static readonly LIDO = new EarnProvider("lido", "Lido");
        static readonly KILN = new EarnProvider("kiln_pooling", "Kiln staking Pool");
      ]])
      assert.equals("lido", p.name.LIDO)
      assert.equals("kiln_pooling", p.name.KILN)
      assert.equals("Lido", p.uiName.LIDO)
    end)

    it("returns empty maps for non-string / empty input", function()
      assert.same({ name = {}, uiName = {} }, tn.parse_providers(nil))
      assert.same({ name = {}, uiName = {} }, tn.parse_providers(""))
    end)
  end)

  -- ── array-of-object-literals parsing ────────────────────────────────────
  describe("parse_object_array", function()
    it("extracts enum-ref fields from each object literal (named array)", function()
      local _, els = tn.parse_object_array(
        [[
        const providerFlowTests = [
          { fromAccount: Account.ETH_1, provider: SwapProvider.ONE_INCH, xrayTicket: "B2CQA-3120" },
          { fromAccount: TokenAccount.ETH_USDT_1, provider: SwapProvider.OKX, xrayTicket: "B2CQA-4728" },
        ];
      ]],
        "providerFlowTests"
      )
      assert.equals(2, #els)
      assert.same({ class = "SwapProvider", sym = "ONE_INCH" }, els[1].provider)
      assert.same({ class = "Account", sym = "ETH_1" }, els[1].fromAccount)
      assert.same({ class = "SwapProvider", sym = "OKX" }, els[2].provider)
      -- string fields (xrayTicket) are ignored, not stored as refs.
      assert.is_nil(els[1].xrayTicket)
    end)

    it("ignores object fields whose value is not a known enum class", function()
      local _, els = tn.parse_object_array("const a = [ { currency: Currency.BTC, foo: Bar.BAZ } ];", "a")
      assert.same({ class = "Currency", sym = "BTC" }, els[1].currency)
      assert.is_nil(els[1].foo)
    end)

    it("returns nil name when the named array is absent", function()
      local name = tn.parse_object_array("const other = [];", "missing")
      assert.is_nil(name)
    end)
  end)

  -- ── for-loop header + parameterized title parsing ────────────────────────
  describe("parse_loop_title", function()
    it("parses a DESTRUCTURED loop + test.describe title (swap flow)", function()
      local loop = tn.parse_loop_title(
        [[
        for (const { fromAccount, toAccount, provider } of providerFlowTests) {
          test.describe(`Swap - ${provider.uiName} flow`, () => {});
        }
      ]],
        "providerFlowTests"
      )
      assert.equals("providerFlowTests", loop.array)
      assert.equals("destructure", loop.binding.kind)
      assert.same({ "fromAccount", "toAccount", "provider" }, loop.binding.fields)
      assert.equals("Swap - %s flow", loop.template)
      assert.same({ { head = "provider", path = { "uiName" } } }, loop.accessors)
    end)

    it("parses a PLAIN-IDENT loop + test() title (add account)", function()
      local loop = tn.parse_loop_title(
        [[
        for (const currency of currencies) {
          test(`[${currency.currency.name}] Add account`, () => {});
        }
      ]],
        "currencies"
      )
      assert.equals("ident", loop.binding.kind)
      assert.equals("currency", loop.binding.var)
      assert.equals("[%s] Add account", loop.template)
      assert.same({ { head = "currency", path = { "currency", "name" } } }, loop.accessors)
    end)

    it("returns nil when the loop or a resolvable title is absent", function()
      assert.is_nil(tn.parse_loop_title("const x = [];", "x"))
      assert.is_nil(tn.parse_loop_title(nil))
    end)
  end)

  -- ── full mini Shape-B end-to-end (pure, no disk) ─────────────────────────
  describe("resolve_desktop_from_sources", function()
    it("resolves a destructured provider flow → 'Swap - <uiName> flow'", function()
      local names = tn.resolve_desktop_from_sources({
        provider = [[
          static readonly ONE_INCH = new SwapProvider("oneinch", "1inch", false, true);
          static readonly OKX = new SwapProvider("okx", "OKX", false, false);
        ]],
        specs = {
          {
            array = "providerFlowTests",
            src = [[
              const providerFlowTests = [
                { fromAccount: Account.ETH_1, provider: SwapProvider.ONE_INCH },
                { fromAccount: Account.ETH_1, provider: SwapProvider.OKX },
              ];
              for (const { fromAccount, provider } of providerFlowTests) {
                test.describe(`Swap - ${provider.uiName} flow`, () => {});
              }
            ]],
          },
        },
      })
      assert.same({ "Swap - 1inch flow", "Swap - OKX flow" }, names)
    end)

    it("resolves a plain-ident currency loop → '[<name>] Add account'", function()
      local names = tn.resolve_desktop_from_sources({
        currency = [[
          static readonly BTC = new Currency("Bitcoin", "BTC", "bitcoin", A, []);
          static readonly ETH = new Currency("Ethereum", "ETH", "ethereum", A, []);
        ]],
        specs = {
          {
            array = "currencies",
            src = [[
              const currencies = [
                { currency: Currency.BTC, xrayTicket: "X" },
                { currency: Currency.ETH, xrayTicket: "Y" },
              ];
              for (const currency of currencies) {
                test(`[${currency.currency.name}] Add account`, () => {});
              }
            ]],
          },
        },
      })
      assert.same({ "[Bitcoin] Add account", "[Ethereum] Add account" }, names)
    end)

    it("resolves a direct-literal title outside the loop (Aleo case)", function()
      local names = tn.resolve_desktop_from_sources({
        currency = 'static readonly ALEO = new Currency("Aleo", "ALEO", "aleo", A, []);',
        specs = {
          {
            array = "currencies",
            src = [[
              test(`[${Currency.ALEO.name}] Add account`, () => {});
            ]],
          },
        },
      })
      assert.same({ "[Aleo] Add account" }, names)
    end)

    it("uses the EXACT accessor: earn uses .name, not .uiName", function()
      local names = tn.resolve_desktop_from_sources({
        provider = 'static readonly LIDO = new EarnProvider("lido", "Lido");',
        specs = {
          {
            array = "earnFlows",
            src = [[
              const earnFlows = [ { provider: EarnProvider.LIDO } ];
              for (const { provider } of earnFlows) {
                test.describe(`Stake via ${provider.name}`, () => {});
              }
            ]],
          },
        },
      })
      -- .name → "lido" (NOT the uiName "Lido"): proves the accessor is honored.
      assert.same({ "Stake via lido" }, names)
    end)

    it("skips an element whose enum ref can't be resolved (no half-name)", function()
      local names = tn.resolve_desktop_from_sources({
        currency = 'static readonly BTC = new Currency("Bitcoin", "BTC", "bitcoin", A, []);',
        specs = {
          {
            array = "currencies",
            src = [[
              const currencies = [
                { currency: Currency.BTC },
                { currency: Currency.UNKNOWN },
              ];
              for (const currency of currencies) {
                test(`[${currency.currency.name}] Add account`, () => {});
              }
            ]],
          },
        },
      })
      assert.same({ "[Bitcoin] Add account" }, names)
    end)

    it("ignores a commented-out array element (disabled currency)", function()
      local names = tn.resolve_desktop_from_sources({
        currency = [[
          static readonly BTC = new Currency("Bitcoin", "BTC", "bitcoin", A, []);
          static readonly TON = new Currency("Gram", "GRAM", "ton", A, []);
        ]],
        specs = {
          {
            array = "currencies",
            src = [[
              const currencies = [
                { currency: Currency.BTC },
                // { currency: Currency.TON },
              ];
              for (const currency of currencies) {
                test(`[${currency.currency.name}] Add account`, () => {});
              }
            ]],
          },
        },
      })
      assert.same({ "[Bitcoin] Add account" }, names)
    end)

    it("coverage: no resolved desktop name contains a residual '${'", function()
      local names = tn.resolve_desktop_from_sources({
        currency = 'static readonly BTC = new Currency("Bitcoin", "BTC", "bitcoin", A, []);',
        provider = 'static readonly OKX = new SwapProvider("okx", "OKX", false, false);',
        specs = {
          {
            array = "currencies",
            src = [[
              const currencies = [ { currency: Currency.BTC } ];
              for (const currency of currencies) {
                test(`[${currency.currency.name}] Add account`, () => {});
              }
            ]],
          },
        },
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

  -- ── desktop monorepo integration (skips cleanly without a checkout) ──────
  describe("resolve_desktop (monorepo)", function()
    local ROOT = os.getenv("LEDGER_LIVE_ROOT")
    if not ROOT or ROOT == "" then
      ROOT = vim.fn.expand("~/src/tries/2026-04-08-LedgerHQ-ledger-live")
    end
    local enum_dir = ROOT .. "/libs/ledger-live-common/src/e2e/enum"
    local spec_dir = ROOT .. "/e2e/desktop/tests/specs"
    local have_monorepo = vim.fn.isdirectory(ROOT) == 1
      and vim.fn.filereadable(enum_dir .. "/Currency.ts") == 1
      and vim.fn.filereadable(enum_dir .. "/Provider.ts") == 1
      and vim.fn.filereadable(spec_dir .. "/provider.swap.spec.ts") == 1
      and vim.fn.filereadable(spec_dir .. "/add.account.spec.ts") == 1

    -- Load the 19-name desktop golden fixture (next to this spec file).
    local function load_golden()
      local here = debug.getinfo(1, "S").source:sub(2)
      local dir = vim.fn.fnamemodify(here, ":h")
      local golden = {}
      for _, line in ipairs(vim.fn.readfile(dir .. "/fixtures/ci_desktop_golden.txt")) do
        if line ~= "" then
          golden[line] = true
        end
      end
      return golden
    end

    it("resolves the two M1 specs → the 19 CI golden names (or skips)", function()
      if not have_monorepo then
        pending("monorepo not present at " .. ROOT .. " (set LEDGER_LIVE_ROOT)")
        return
      end
      local names = tn.resolve_desktop(ROOT)
      local golden = load_golden()

      -- Compared as a SET (order is not load-bearing; the fixture is byte-sorted
      -- like the resolver's output but the assertion doesn't depend on it).
      local got = {}
      for _, n in ipairs(names) do
        got[n] = true
      end
      for _, n in ipairs(names) do
        assert.is_true(golden[n] == true, "resolved name not in desktop golden set: " .. n)
      end
      for g in pairs(golden) do
        assert.is_true(got[g] == true, "golden name not produced by resolver: " .. g)
      end
      assert.equals(19, #names, "expected exactly the 19 M1 desktop names, got " .. #names)
    end)

    it("every resolved desktop name is well-formed with no residual '${'", function()
      if not have_monorepo then
        pending("monorepo not present at " .. ROOT)
        return
      end
      local names = tn.resolve_desktop(ROOT)
      for _, n in ipairs(names) do
        -- coverage metric: 0 titles retain an unresolved template var.
        assert.is_nil(n:find("${", 1, true), "residual template var in: " .. n)
        assert.is_truthy(
          n:match("^Swap %- .+ flow$") or n:match("^%[.+%] Add account$"),
          "malformed desktop name: " .. n
        )
      end
    end)
  end)
end)
