.PHONY: setup install init-git-config init-submodules pull-submodules doctor-submodules test lint check verify check-json extract-builtin-catalogs

REFERENCE_SUBMODULES := \
	references/rbs \
	references/rbs-inline-wiki \
	references/phpstan \
	references/python-typing \
	references/ruby \
	references/TypeScript-Website

setup: install init-git-config init-submodules

install:
	bundle install

init-git-config:
	@# Local-only safety defaults for this clone. Idempotent.
	@# Why: submodule.recurse=true on a parent operation amplifies any submodule
	@# breakage into a parent-side fatal. We disable recursion and instead drive
	@# submodule updates explicitly via `make init-submodules` / `make pull-submodules`.
	git config submodule.recurse false
	git config fetch.recurseSubmodules on-demand
	git config status.submoduleSummary true
	git config diff.submodule log
	git config push.recurseSubmodules check
	@echo "Local git submodule-safety config applied."

init-submodules:
	git submodule update --init --filter=blob:none references/rbs
	git submodule update --init --filter=blob:none references/rbs-inline-wiki
	@if [ ! -e references/phpstan/.git ]; then \
		url="$$(git config -f .gitmodules submodule.references/phpstan.url)"; \
		sha="$$(git rev-parse HEAD:references/phpstan)"; \
		echo "Initializing references/phpstan sparsely (website)"; \
		git clone --no-checkout --filter=blob:none "$$url" references/phpstan; \
		git -C references/phpstan fetch origin "$$sha"; \
		git -C references/phpstan sparse-checkout init --cone; \
		git -C references/phpstan sparse-checkout set website; \
		git -C references/phpstan checkout --detach "$$sha"; \
		git submodule absorbgitdirs references/phpstan; \
	else \
		git submodule update --init --filter=blob:none references/phpstan; \
	fi
	git submodule update --init --filter=blob:none references/python-typing
	git submodule update --init --filter=blob:none references/ruby
	@if [ ! -e references/TypeScript-Website/.git ]; then \
		url="$$(git config -f .gitmodules submodule.references/TypeScript-Website.url)"; \
		sha="$$(git rev-parse HEAD:references/TypeScript-Website)"; \
		echo "Initializing references/TypeScript-Website sparsely (packages/documentation/copy/en)"; \
		git clone --no-checkout --filter=blob:none "$$url" references/TypeScript-Website; \
		git -C references/TypeScript-Website fetch origin "$$sha"; \
		git -C references/TypeScript-Website sparse-checkout init --cone; \
		git -C references/TypeScript-Website sparse-checkout set packages/documentation/copy/en; \
		git -C references/TypeScript-Website checkout --detach "$$sha"; \
		git submodule absorbgitdirs references/TypeScript-Website; \
	else \
		git submodule update --init --filter=blob:none references/TypeScript-Website; \
	fi

pull-submodules: init-submodules
	git submodule update --remote --merge $(REFERENCE_SUBMODULES)

doctor-submodules:
	@bin/doctor-submodules

test:
	bundle exec rspec

lint:
	bundle exec rubocop

check:
	bundle exec exe/rigor check lib

check-json:
	bundle exec exe/rigor check --format=json lib

verify: test lint check

extract-builtin-catalogs:
	bundle exec ruby tool/extract_builtin_catalog.rb
