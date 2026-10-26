LUA ?= luajit
LUAC ?= luac5.1
PYTHON ?= python3
KOREADER_DIR ?= ../..
TEST_ARGS ?=
INTEGRATION_ARGS ?=

.PHONY: test syntax coverage integration integration-coverage check check-all

test:
	$(LUA) tests/busted.lua $(TEST_ARGS)

syntax:
	@for file in main.lua _meta.lua .busted .luacov tests/*.lua \
		spec/unit/*.lua spec/support/*.lua spec/integration/*.lua; do \
		$(LUAC) -p "$$file" || exit 1; \
	done

coverage:
	rm -f luacov.stats.out luacov.report.out
	KO_HOME=. $(LUA) tests/busted.lua --coverage $(TEST_ARGS)
	KO_HOME=. $(LUA) -e 'require("luacov.runner").run_report()'
	@sed -n '/^Summary/,$$p' luacov.report.out

integration:
	$(PYTHON) tests/run_koreader.py --koreader-dir "$(KOREADER_DIR)" $(INTEGRATION_ARGS)

integration-coverage:
	$(PYTHON) tests/run_koreader.py --koreader-dir "$(KOREADER_DIR)" \
		--coverage $(INTEGRATION_ARGS)

check: syntax test coverage

check-all: check integration
