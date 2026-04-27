.PHONY: init-submodules pull-submodules

REFERENCE_SUBMODULES := \
	references/rbs \
	references/phpstan \
	references/python-typing \
	references/TypeScript-Website

init-submodules:
	git submodule update --init --filter=blob:none references/rbs
	git submodule update --init --filter=blob:none --no-checkout references/phpstan
	git -C references/phpstan sparse-checkout init --cone
	git -C references/phpstan sparse-checkout set website
	git -C references/phpstan checkout
	git submodule update --init --filter=blob:none references/python-typing
	git submodule update --init --filter=blob:none --no-checkout references/TypeScript-Website
	git -C references/TypeScript-Website sparse-checkout init --cone
	git -C references/TypeScript-Website sparse-checkout set packages/documentation/copy/en
	git -C references/TypeScript-Website checkout

pull-submodules: init-submodules
	git submodule update --remote --merge $(REFERENCE_SUBMODULES)
