LUA ?= luajit
LUAC ?= luac5.1
PYTHON ?= python3
LUACHECK ?= luacheck
KOREADER_DIR ?= ../..
PACKAGE = dist/fastreader.koplugin.zip
TEST_ARGS ?=
INTEGRATION_ARGS ?=

.PHONY: test syntax lint coverage integration integration-coverage package package-check check check-all

test:
	$(LUA) tests/busted.lua $(TEST_ARGS)

syntax:
	@for file in main.lua _meta.lua fastreader/*.lua .busted .luacov tests/*.lua \
		spec/unit/*.lua spec/support/*.lua spec/integration/*.lua; do \
		$(LUAC) -p "$$file" || exit 1; \
	done

lint:
	$(LUACHECK) --no-config --std luajit --no-unused-args --no-self \
		--no-max-line-length main.lua _meta.lua fastreader
	$(LUACHECK) --no-config --std luajit+busted --no-unused-args --no-self \
		--max-line-length 100 spec tests/busted.lua .busted .luacov

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

package:
	@mkdir -p dist
	@set -eu; staging=$$(mktemp -d); \
		trap 'rm -rf "$$staging"' EXIT HUP INT TERM; \
		mkdir "$$staging/fastreader.koplugin"; \
		cp main.lua _meta.lua LICENSE README.md rsvp.gif settings.png \
			"$$staging/fastreader.koplugin/"; \
		cp -R fastreader "$$staging/fastreader.koplugin/"; \
		rm -f "$(PACKAGE)"; \
		cd "$$staging" && $(PYTHON) -m zipfile -c "$(abspath $(PACKAGE))" fastreader.koplugin
	@echo "Created $(PACKAGE)"

package-check: package
	$(PYTHON) tests/run_koreader.py --koreader-dir "$(KOREADER_DIR)" \
		--plugin-zip "$(PACKAGE)" $(INTEGRATION_ARGS)

check: syntax lint test coverage

check-all: check integration package-check
