all: test

CC_BRANCH ?= main

test: deps/mini.test
	@echo "Running tests..."
	nvim --headless --noplugin -u scripts/minimal_init.lua -c "lua MiniTest.run()"

test-compat: deps/mini.test deps/plenary.nvim
	@rm -rf deps/codecompanion.nvim
	git clone --filter=blob:none --branch $(CC_BRANCH) https://github.com/olimorris/codecompanion.nvim deps/codecompanion.nvim
	@echo "Running API compatibility tests against codecompanion.nvim ($(CC_BRANCH))..."
	nvim --headless --noplugin -u scripts/minimal_init.lua -c "lua MiniTest.run_file('tests_compat/test_cc_api_compat.lua')"

deps/mini.test:
	@mkdir -p deps
	git clone --filter=blob:none https://github.com/echasnovski/mini.test $@

deps/plenary.nvim:
	git clone --filter=blob:none https://github.com/nvim-lua/plenary.nvim $@

format:
	@stylua .

testFile:
	@if [ -z "$(FILE)" ]; then echo "Usage: make testFile FILE=path/to/test.lua"; exit 1; fi
	@echo "Running test $(FILE)..."
	nvim --headless --noplugin -u scripts/minimal_init.lua -c "lua MiniTest.run({\"$(FILE)\"})"

.PHONY: all test test-compat format testFile
