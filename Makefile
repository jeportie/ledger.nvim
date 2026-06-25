.PHONY: test test-integration lint format

test:
	nvim --headless -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}" \
		-c "qa!"

# Local-only: real-build parity + state checks against a ledger-live checkout.
#   LEDGER_LIVE_ROOT=~/src/…-ledger-live make test-integration
test-integration:
	nvim --headless -u tests/minimal_init.lua \
		-c "PlenaryBustedFile tests/integration_spec.lua" \
		-c "qa!"

lint:
	stylua --check lua/ tests/

format:
	stylua lua/ tests/