# frozen_string_literal: true

# Gem entry point for the out-of-tree fixture plugin. A third-party
# `rigor-*` gem (ADR-31 WD4) ships exactly this shape: a top-level
# `lib/rigor-<id>.rb` the plugin loader `require`s by gem name, which
# pulls in the plugin class.
require_relative "rigor/plugin/external_demo"
