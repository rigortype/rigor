# frozen_string_literal: true

# Gem entry point. Required by Rigor's plugin loader when
# `.rigor.yml` lists `rigor-typescript-utility-types` under
# `plugins:`. The loader expects this `require` to side-effect
# a call to `Rigor::Plugin.register`, which the body of
# `lib/rigor/plugin/typescript_utility_types.rb` performs at
# load time.
require_relative "rigor/plugin/typescript_utility_types"
