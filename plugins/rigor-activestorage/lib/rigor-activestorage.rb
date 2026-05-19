# frozen_string_literal: true

# Entry point matching the `rigor-<id>` gem-name convention.
# The Plugin::Loader's `require_gem!` step calls
# `require "rigor-activestorage"`, and this file loads the
# plugin's actual implementation under the `rigor/plugin/`
# namespace so the require / register pair fires.
require "rigor/plugin/activestorage"
