# frozen_string_literal: true

# Gem entry point. Required by Rigor's plugin loader when
# `.rigor.yml` lists `rigor-statesman` under `plugins:`. The
# loader expects this `require` to side-effect a call to
# `Rigor::Plugin.register`, which the body of
# `lib/rigor/plugin/statesman.rb` performs at load time.
require_relative "rigor/plugin/statesman"
