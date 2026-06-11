-- luacheck config for ledger.nvim
--
-- Scope: catch correctness problems (syntax errors, undefined globals, typo'd
-- requires). Formatting/whitespace and most stylistic warnings are stylua's
-- job, so the noisy classes are ignored to keep the gate meaningful rather
-- than a churny style linter over the migrated codebase.

std = "luajit"
cache = true
codes = true

-- `vim` is the only ambient global the plugin relies on.
globals = { "vim" }

-- stylua owns line width and whitespace.
max_line_length = false

ignore = {
  "21.", -- unused argument / loop variable / local (211,212,213)
  "23.", -- unused/used-only-in-scope field warnings
  "3..", -- shadowing, redefinition of locals/args
  "4..", -- shadowing/mutating upvalues and fields
  "5..", -- control-flow style (empty branches, etc.)
  "6..", -- whitespace / formatting (owned by stylua)
}

-- Test files use plenary's busted-style globals.
files["tests/"] = {
  std = "+busted",
  globals = { "assert" },
}
