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
    it("prefers libs/live-e2e-shared/src/enum first (the #19312 location)", function()
      local root = mk("libs/live-e2e-shared/src/enum")
      assert.equals(root .. "/libs/live-e2e-shared/src/enum", tn._detect_enum_dir(root))
    end)
    it("falls back to e2e/shared/src/enum", function()
      local root = mk("e2e/shared/src/enum")
      assert.equals(root .. "/e2e/shared/src/enum", tn._detect_enum_dir(root))
    end)
    it("falls back to the old libs/ledger-live-common path", function()
      local root = mk("libs/ledger-live-common/src/e2e/enum")
      assert.equals(root .. "/libs/ledger-live-common/src/e2e/enum", tn._detect_enum_dir(root))
    end)
    it("defaults to the newest path when none exists", function()
      local root = vim.fn.tempname()
      assert.equals(root .. "/libs/live-e2e-shared/src/enum", tn._detect_enum_dir(root))
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
      -- Single parameterized title in this loop → one entry.
      assert.equals(1, #loop.titles)
      assert.equals("Swap - %s flow", loop.titles[1].template)
      assert.same({ { head = "provider", path = { "uiName" } } }, loop.titles[1].accessors)
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
      assert.equals(1, #loop.titles)
      assert.equals("[%s] Add account", loop.titles[1].template)
      assert.same({ { head = "currency", path = { "currency", "name" } } }, loop.titles[1].accessors)
    end)

    it("captures BOTH the describe + inner test titles in a loop (earn shape)", function()
      -- earn's loops wrap a parameterized `test.describe` around a DISTINCT
      -- parameterized inner `test`; both titles must be captured, in source order.
      local loop = tn.parse_loop_title(
        [[
        for (const { account, xrayTicket } of coldStartCurrencies) {
          test.describe(`Cold start - ${account.currency.ticker}`, () => {
            test(
              `Earn v2 cold start page shows ${account.currency.ticker} ready to earn`,
              { tag: [] },
              async ({ app }) => {},
            );
          });
        }
      ]],
        "coldStartCurrencies"
      )
      assert.equals("destructure", loop.binding.kind)
      assert.equals(2, #loop.titles)
      assert.equals("Cold start - %s", loop.titles[1].template)
      assert.equals("Earn v2 cold start page shows %s ready to earn", loop.titles[2].template)
      -- both interpolate the SAME accessor (account.currency.ticker)
      assert.same({ { head = "account", path = { "currency", "ticker" } } }, loop.titles[1].accessors)
      assert.same({ { head = "account", path = { "currency", "ticker" } } }, loop.titles[2].accessors)
    end)

    it("scopes titles to THIS loop when several loops share the source", function()
      -- The body must be sliced from the requested array's header to the next
      -- `for (const …`, so a later loop's title never leaks into an earlier one.
      local src = [[
        for (const { account } of coldStartCurrencies) {
          test.describe(`Cold start - ${account.currency.ticker}`, () => {});
        }
        for (const { provider } of ethProviders) {
          test.describe(`ETH staking flow - ${provider.name}`, () => {});
        }
      ]]
      local cold = tn.parse_loop_title(src, "coldStartCurrencies")
      assert.equals(1, #cold.titles)
      assert.equals("Cold start - %s", cold.titles[1].template)
      local eth = tn.parse_loop_title(src, "ethProviders")
      assert.equals(1, #eth.titles)
      assert.equals("ETH staking flow - %s", eth.titles[1].template)
      assert.same({ { head = "provider", path = { "name" } } }, eth.titles[1].accessors)
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

    it("resolves BOTH the describe + inner test title per element (earn cold start)", function()
      -- Mirrors earn.v2.spec.ts: a `test.describe(`Cold start - …`)` wrapping a
      -- DISTINCT inner `test(`Earn v2 cold start … ready to earn`)`, over two
      -- accounts → 4 concrete names (2 titles × 2 elements).
      local names = tn.resolve_desktop_from_sources({
        currency = [[
          static readonly ETH = new Currency("Ethereum", "ETH", "ethereum", A, []);
          static readonly ATOM = new Currency("Cosmos", "ATOM", "cosmos", A, []);
        ]],
        account = [[
          static readonly ETH_2 = new Account(Currency.ETH, "Ethereum 2", 1, "p");
          static readonly ATOM_2 = new Account(Currency.ATOM, "Cosmos 2", 1, "p");
        ]],
        specs = {
          {
            array = "coldStartCurrencies",
            src = [[
              const coldStartCurrencies = [
                { account: Account.ETH_2, xrayTicket: "B2CQA-4640" },
                { account: Account.ATOM_2, xrayTicket: "B2CQA-4719" },
              ];
              for (const { account, xrayTicket } of coldStartCurrencies) {
                test.describe(`Cold start - ${account.currency.ticker}`, () => {
                  test(
                    `Earn v2 cold start page shows ${account.currency.ticker} ready to earn`,
                    { tag: [] },
                    async ({ app }) => {},
                  );
                });
              }
            ]],
          },
        },
      })
      -- SORTED output: both describe titles and both leaf titles, per element.
      assert.same({
        "Cold start - ATOM",
        "Cold start - ETH",
        "Earn v2 cold start page shows ATOM ready to earn",
        "Earn v2 cold start page shows ETH ready to earn",
      }, names)
    end)

    it("resolves an earn provider loop's leaf title via provider.name", function()
      local names = tn.resolve_desktop_from_sources({
        provider = [[
          static readonly LIDO = new EarnProvider("lido", "Lido");
          static readonly KILN = new EarnProvider("kiln_pooling", "Kiln staking Pool");
        ]],
        specs = {
          {
            array = "ethProviders",
            src = [[
              const ethProviders = [
                { provider: EarnProvider.LIDO, xrayTickets: ["B2CQA-4722"] },
                { provider: EarnProvider.KILN, xrayTickets: ["B2CQA-4724"] },
              ];
              for (const { provider, xrayTickets } of ethProviders) {
                test.describe(`ETH staking flow - ${provider.name}`, () => {
                  test(
                    `Earn v2 ETH staking flow - ${provider.name}`,
                    { tag: [] },
                    async ({ app, page }) => {},
                  );
                });
              }
            ]],
          },
        },
      })
      -- provider.name → "lido"/"kiln_pooling" (the leaf CI records), sorted.
      assert.same({
        "ETH staking flow - kiln_pooling",
        "ETH staking flow - lido",
        "Earn v2 ETH staking flow - kiln_pooling",
        "Earn v2 ETH staking flow - lido",
      }, names)
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

  -- ── mobile EARN "Shape-C": testConfig object literal + earnV2 helper titles ─
  -- Each earn spec sets `const testConfig = { account: Account.X, provider:
  -- EarnProvider.Y, … }` then calls `run*Test(testConfig.account,
  -- testConfig.provider.name, …)`; the it() titles live in earnV2.ts. Titles use
  -- account.currency.ticker, a bare providerId (bound to testConfig.provider.name),
  -- and — the gotcha — account.currency.speculosApp.name (NEAR → "Near", ≠ ticker
  -- "NEAR"), which needs the AppInfos table + a resolve-hop.
  describe("mobile earn (Shape-C)", function()
    local CURRENCY = [[
      static readonly ETH = new Currency("Ethereum", "ETH", "ethereum", AppInfos.ETHEREUM, [Network.ETH]);
      static readonly NEAR = new Currency("NEAR", "NEAR", "near", AppInfos.NEAR, [Network.NEAR]);
      static readonly ATOM = new Currency("Cosmos", "ATOM", "cosmos", AppInfos.COSMOS, [Network.ATOM]);
      static readonly ETH_USDT = new Currency("Tether USD", "USDT", "eth/usdt", AppInfos.ETHEREUM, [Network.ETH]);
    ]]
    local ACCOUNT = [[
      static readonly ETH_1 = new Account(Currency.ETH, "Ethereum 1", 0);
      static readonly ETH_2 = new Account(Currency.ETH, "Ethereum 2", 1);
      static readonly NEAR_1 = new Account(Currency.NEAR, "Near 1", 0);
      static readonly ETH_USDT_1 = new TokenAccount(Currency.ETH_USDT, "USDT 1", 0);
    ]]
    local PROVIDER = [[
      static readonly KILN = new EarnProvider("kiln_pooling", "Kiln staking Pool");
      static readonly STADER_LABS = new EarnProvider("stader-eth", "Stader Labs");
    ]]
    local APPINFOS = [[
      static readonly ETHEREUM = new AppInfos("Ethereum");
      static readonly NEAR = new AppInfos("Near");
      static readonly COSMOS = new AppInfos("Cosmos");
    ]]
    -- earnV2.ts: helpers with describe()+it(); ice-cold-start's it is STATIC.
    -- runPartnerDappCTATest has a multi-line signature (params over several lines).
    local HELPER = [[
export function runColdStartTest(account: Account, tmsLinks: string[], tags: string[]) {
  describe(`Earn V2 - Cold start - ${account.currency.ticker}`, () => {
    it(`shows ${account.currency.ticker} ready to earn and clicking CTA initiates staking`, async () => {});
  });
}
export function runPartnerDappCTATest(
  account: Account,
  providerId: string,
  dappUrlSubstring: string,
  tmsLinks: string[],
  tags: string[],
) {
  describe(`Earn V2 - CTA -> Partner dapp (${account.currency.ticker} / ${providerId})`, () => {
    it(`${account.currency.ticker} earn CTA -> ${providerId} provider -> dapp`, async () => {});
  });
}
export function runInlineAddAccountTest(account: Account, tmsLinks: string[], tags: string[]) {
  describe("Earn V2 - Inline Add Account", () => {
    it(`Inline Add Account [${account.currency.speculosApp.name}]`, async () => {});
  });
}
export function runIceColdStartTest(account: Account, tmsLinks: string[], tags: string[]) {
  describe("Earn V2 - Ice cold start", () => {
    it("displays ice cold start page and CTA opens modular asset drawer", async () => {});
  });
}
    ]]
    local SPEC_COLD = [[
import { Account } from "@ledgerhq/live-e2e-shared/enum/Account";
import { runColdStartTest } from "./earnV2";
const testConfig = { account: Account.ETH_2, tmsLinks: ["B2CQA-4640"], tags: ["@ethereum"] };
runColdStartTest(testConfig.account, testConfig.tmsLinks, testConfig.tags);
    ]]
    local SPEC_KILN = [[
import { Account } from "@ledgerhq/live-e2e-shared/enum/Account";
import { EarnProvider } from "@ledgerhq/live-e2e-shared/enum/Provider";
import { runPartnerDappCTATest } from "./earnV2";
const testConfig = {
  account: Account.ETH_1,
  provider: EarnProvider.KILN,
  dappUrlSubstring: "ledger-staking.widget.kiln.fi/earn",
  tmsLinks: ["B2CQA-4724"],
  tags: ["@ethereum"],
};
runPartnerDappCTATest(
  testConfig.account,
  testConfig.provider.name,
  testConfig.dappUrlSubstring,
  testConfig.tmsLinks,
  testConfig.tags,
);
    ]]
    -- STADER: the dappUrlSubstring carries a DECOY direct enum ref inside a
    -- template string — it must NOT be scraped as testConfig.provider.
    local SPEC_STADER = [[
import { runPartnerDappCTATest } from "./earnV2";
const testConfig = {
  account: Account.ETH_1,
  provider: EarnProvider.STADER_LABS,
  dappUrlSubstring: `staderlabs.com/${Account.ETH_1.currency.ticker}`,
  tmsLinks: ["B2CQA-1"],
  tags: ["@ethereum"],
};
runPartnerDappCTATest(testConfig.account, testConfig.provider.name, testConfig.dappUrlSubstring, testConfig.tmsLinks, testConfig.tags);
    ]]
    -- Inline-add with NEAR proves the speculosApp.name hop resolves to the
    -- AppInfos name "Near", NOT the ticker "NEAR" nor the currency name "NEAR".
    local SPEC_INLINE_NEAR = [[
import { Account } from "@ledgerhq/live-e2e-shared/enum/Account";
import { runInlineAddAccountTest } from "./earnV2";
const testConfig = { account: Account.NEAR_1, tmsLinks: ["B2CQA-3001"], tags: ["@near"] };
runInlineAddAccountTest(testConfig.account, testConfig.tmsLinks, testConfig.tags);
    ]]
    local SPEC_ICE = [[
import { runIceColdStartTest } from "./earnV2";
const testConfig = { account: Account.ETH_1, tmsLinks: ["B2CQA-1"], tags: ["@x"] };
runIceColdStartTest(testConfig.account, testConfig.tmsLinks, testConfig.tags);
    ]]

    it("parse_appinfos: SYM → display name", function()
      local ai = tn.parse_appinfos(APPINFOS)
      assert.equals("Ethereum", ai.ETHEREUM)
      assert.equals("Near", ai.NEAR)
      assert.equals("Cosmos", ai.COSMOS)
    end)

    it("parse_currency_speculos: currency SYM → AppInfos SYM (the 4th ctor arg)", function()
      local sp = tn.parse_currency_speculos(CURRENCY)
      assert.equals("ETHEREUM", sp.ETH)
      assert.equals("NEAR", sp.NEAR)
      assert.equals("COSMOS", sp.ATOM)
      assert.equals("ETHEREUM", sp.ETH_USDT)
    end)

    it("parse_object_literal: captures account/provider, ignores a decoy in a string field", function()
      local obj = tn.parse_object_literal(SPEC_STADER)
      assert.same({ class = "Account", sym = "ETH_1" }, obj.account)
      assert.same({ class = "EarnProvider", sym = "STADER_LABS" }, obj.provider)
      assert.is_nil(obj.dappUrlSubstring) -- the ${Account.ETH_1…} decoy is not a field ref
    end)

    it("parse_earn_helpers: params + parameterized it; skips a static-it helper", function()
      local h = tn.parse_earn_helpers(HELPER)
      assert.same({ "account", "tmsLinks", "tags" }, h.runColdStartTest.params)
      assert.same({ "account", "providerId", "dappUrlSubstring", "tmsLinks", "tags" }, h.runPartnerDappCTATest.params)
      assert.is_truthy(h.runInlineAddAccountTest)
      assert.is_nil(h.runIceColdStartTest) -- its it() is a plain string → nothing to resolve
    end)

    it("parse_earn_call: helper name + positional testConfig field/leaf args", function()
      local c = tn.parse_earn_call(SPEC_KILN)
      assert.equals("runPartnerDappCTATest", c.helper)
      assert.same({ field = "account" }, c.args[1])
      assert.same({ field = "provider", leaf = "name" }, c.args[2])
    end)

    it("resolve_earn_from_sources: ticker, provider.name, and speculosApp.name shapes", function()
      local names = tn.resolve_earn_from_sources({
        currency = CURRENCY,
        account = ACCOUNT,
        provider = PROVIDER,
        appinfos = APPINFOS,
        helper = HELPER,
        specs = {
          { src = SPEC_COLD, spec = "specs/earn/earnV2_coldStart_ETH_2.spec.ts" },
          { src = SPEC_KILN, spec = "specs/earn/earnV2_CTA_partnerDapp_ETH_KILN.spec.ts" },
          { src = SPEC_STADER, spec = "specs/earn/earnV2_CTA_partnerDapp_ETH_STADER_LABS.spec.ts" },
          { src = SPEC_INLINE_NEAR, spec = "specs/earn/earnInlineAddAccount.spec.ts" },
          { src = SPEC_ICE, spec = "specs/earn/earnV2_iceColdStart_ETH_3.spec.ts" },
        },
      })
      assert.same({
        "ETH earn CTA -> kiln_pooling provider -> dapp",
        "ETH earn CTA -> stader-eth provider -> dapp",
        "Inline Add Account [Near]",
        "shows ETH ready to earn and clicking CTA initiates staking",
      }, names)
    end)

    it("resolve_earn_from_sources: a static-it spec yields nothing (already scraped verbatim)", function()
      local names = tn.resolve_earn_from_sources({
        currency = CURRENCY,
        account = ACCOUNT,
        provider = PROVIDER,
        appinfos = APPINFOS,
        helper = HELPER,
        specs = { { src = SPEC_ICE } },
      })
      assert.same({}, names)
    end)

    it("resolve_earn_from_sources: a missing AppInfos source drops only the speculosApp name", function()
      local names = tn.resolve_earn_from_sources({
        currency = CURRENCY,
        account = ACCOUNT,
        provider = PROVIDER, -- no appinfos → the inline-add name can't resolve
        helper = HELPER,
        specs = { { src = SPEC_COLD }, { src = SPEC_INLINE_NEAR } },
      })
      assert.same({ "shows ETH ready to earn and clicking CTA initiates staking" }, names)
    end)

    it("earn_entries_from_sources: pins each resolved name to its spec (picker wiring)", function()
      local entries = tn.earn_entries_from_sources({
        currency = CURRENCY,
        account = ACCOUNT,
        provider = PROVIDER,
        appinfos = APPINFOS,
        helper = HELPER,
        specs = {
          { src = SPEC_KILN, spec = "specs/earn/earnV2_CTA_partnerDapp_ETH_KILN.spec.ts" },
          { src = SPEC_INLINE_NEAR, spec = "specs/earn/earnInlineAddAccount.spec.ts" },
        },
      })
      local by_name = {}
      for _, e in ipairs(entries) do
        by_name[e.name] = e.spec
      end
      assert.equals(
        "specs/earn/earnV2_CTA_partnerDapp_ETH_KILN.spec.ts",
        by_name["ETH earn CTA -> kiln_pooling provider -> dapp"]
      )
      assert.equals("specs/earn/earnInlineAddAccount.spec.ts", by_name["Inline Add Account [Near]"])
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

  -- ── desktop EARN monorepo integration (skips cleanly without a checkout) ──
  -- Guards on the DETECTED enum dir (earn's checkout moved enums to
  -- e2e/shared/src/enum), so this actually runs against the real spec rather than
  -- pending()-ing on the pre-refactor path. Validates the 7 parameterized `test()`
  -- LEAF names (CI run 28432194879) are a SUBSET of the resolver output — the
  -- resolver also emits the outer `describe` titles ("Cold start - ETH", …), which
  -- are additional runnable names and intentionally not asserted here.
  describe("resolve_desktop earn (monorepo)", function()
    local ROOT = os.getenv("LEDGER_LIVE_ROOT")
    if not ROOT or ROOT == "" then
      ROOT = vim.fn.expand("~/src/tries/2026-04-08-LedgerHQ-ledger-live")
    end
    local enum_dir = tn._detect_enum_dir(ROOT)
    local spec_dir = ROOT .. "/e2e/desktop/tests/specs"
    local have_monorepo = vim.fn.isdirectory(ROOT) == 1
      and vim.fn.filereadable(enum_dir .. "/Currency.ts") == 1
      and vim.fn.filereadable(enum_dir .. "/Account.ts") == 1
      and vim.fn.filereadable(enum_dir .. "/Provider.ts") == 1
      and vim.fn.filereadable(spec_dir .. "/earn.v2.spec.ts") == 1

    -- The 7 parameterized earn `test()` leaf names recorded by CI.
    local EARN_GOLDEN = {
      "Earn v2 cold start page shows ETH ready to earn",
      "Earn v2 cold start page shows ATOM ready to earn",
      "Earn v2 hot start page shows SOL with rewards and navigates to account",
      "Earn v2 hot start page shows NEAR with rewards and navigates to account",
      "Earn v2 hot start page shows ATOM with rewards and navigates to account",
      "Earn v2 ETH staking flow - lido",
      "Earn v2 ETH staking flow - kiln_pooling",
    }

    it("resolve_desktop includes the 7 earn leaf names, no residual '${' (or skips)", function()
      if not have_monorepo then
        pending("monorepo not present at " .. ROOT .. " (set LEDGER_LIVE_ROOT)")
        return
      end
      local names = tn.resolve_desktop(ROOT)
      local got = {}
      for _, n in ipairs(names) do
        got[n] = true
        assert.is_nil(n:find("${", 1, true), "residual template var in: " .. n)
      end
      for _, g in ipairs(EARN_GOLDEN) do
        assert.is_true(got[g] == true, "earn golden leaf name not produced by resolver: " .. g)
      end
    end)

    it("picker_entries(desktop) pairs the 7 earn leaf names with earn.v2.spec.ts (or skips)", function()
      if not have_monorepo then
        pending("monorepo not present at " .. ROOT)
        return
      end
      local entries = tn.picker_entries(ROOT, "desktop")
      local spec_of = {}
      for _, e in ipairs(entries) do
        spec_of[e.name] = e.spec
      end
      for _, g in ipairs(EARN_GOLDEN) do
        assert.equals("tests/specs/earn.v2.spec.ts", spec_of[g], "earn golden name missing/mis-specced: " .. g)
      end
    end)
  end)

  -- ── mobile earn monorepo integration (skips cleanly without a checkout) ──
  -- Guard uses _detect_enum_dir + the newest local checkout (or LEDGER_LIVE_ROOT),
  -- so it actually runs against a present checkout rather than a pinned stale path.
  describe("resolve_earn (monorepo)", function()
    local ROOT = os.getenv("LEDGER_LIVE_ROOT")
    if not ROOT or ROOT == "" then
      local cks = vim.fn.glob(vim.fn.expand("~/src/tries") .. "/*-LedgerHQ-ledger-live", true, true)
      table.sort(cks)
      ROOT = cks[#cks] or vim.fn.expand("~/src/tries/2026-05-11-LedgerHQ-ledger-live")
    end
    local enum_dir = tn._detect_enum_dir(ROOT)
    local earn_dir = ROOT .. "/e2e/mobile/specs/earn"
    local have_monorepo = vim.fn.filereadable(enum_dir .. "/Currency.ts") == 1
      and vim.fn.filereadable(enum_dir .. "/AppInfos.ts") == 1
      and vim.fn.filereadable(earn_dir .. "/earnV2.ts") == 1

    it("resolves every earn spec to a concrete it() name (or skips w/o monorepo)", function()
      if not have_monorepo then
        pending("monorepo not present at " .. ROOT .. " (set LEDGER_LIVE_ROOT)")
        return
      end
      local names = tn.resolve_earn(ROOT)
      assert.is_true(#names >= 13, "expected >= 13 earn names, got " .. #names)
      for _, n in ipairs(names) do
        assert.is_nil(n:find("${", 1, true), "residual template var in: " .. n)
        assert.is_truthy(n:match("%S"), "empty earn name")
      end
    end)

    it("resolved earn names are all in the CI golden fixture (or skips)", function()
      if not have_monorepo then
        pending("monorepo not present at " .. ROOT)
        return
      end
      local here = debug.getinfo(1, "S").source:sub(2)
      local dir = vim.fn.fnamemodify(here, ":h")
      local golden = {}
      for _, line in ipairs(vim.fn.readfile(dir .. "/fixtures/ci_earn_golden.txt")) do
        if line ~= "" then
          golden[line] = true
        end
      end
      for _, n in ipairs(tn.resolve_earn(ROOT)) do
        assert.is_true(golden[n] == true, "resolved earn name not in CI golden set: " .. n)
      end
    end)
  end)
end)
