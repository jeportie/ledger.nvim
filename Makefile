.PHONY: test lint format

test:
	nvim --headless -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}" \
		-c "qa!"

lint:
	stylua --check lua/ tests/

format:
	stylua lua/ tests/