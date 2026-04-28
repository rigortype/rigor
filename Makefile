.PHONY: setup install init-submodules pull-submodules

REFERENCE_SUBMODULES := \
	references/rbs \
	references/rbs-inline-wiki \
	references/phpstan \
	references/python-typing \
	references/TypeScript-Website

setup: install init-submodules

install:
	bundle install

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
