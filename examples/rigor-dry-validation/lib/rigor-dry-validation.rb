# frozen_string_literal: true

# Gem entry point. Required by Rigor's plugin loader when
# `.rigor.yml` lists `rigor-dry-validation` under `plugins:`.
# Side-effects a `Rigor::Plugin.register` call via the
# `lib/rigor/plugin/dry_validation.rb` class body.
require_relative "rigor/plugin/dry_validation"
