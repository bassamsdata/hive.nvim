all: test

test: deps
	@echo "Running tests..."
	nvim --headless --noplugin -u scripts/minimal_init.lua -c "lua MiniTest.run(vim.tbl_filter(function(x) return x:match('^tests/test_.*%%.lua') end, vim.fn.glob('tests/*', true, true)))"

deps: deps/mini.nvim

deps/mini.nvim:
	@mkdir -p deps
	git clone --filter=blob:none https://github.com/echasnovski/mini.nvim $@

format:
	@stylua .

testFile:
	@if [ -z "$(FILE)" ]; then echo "Usage: make testFile FILE=path/to/test.lua"; exit 1; fi
	@echo "Running test $(FILE)..."
	nvim --headless --noplugin -u scripts/minimal_init.lua -c "lua MiniTest.run({\"$(FILE)\"})"

.PHONY: all test deps format
