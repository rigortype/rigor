# frozen_string_literal: true

# Gem entry point. Required by Rigor's plugin loader when
# `.rigor.yml` lists `rigor-deprecations` under `plugins:`.
require_relative "rigor/plugin/deprecations"
