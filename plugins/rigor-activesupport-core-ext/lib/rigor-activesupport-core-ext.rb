# frozen_string_literal: true

# rigor-activesupport-core-ext — a community-maintained RBS bundle for the most-frequently-flagged
# ActiveSupport core extensions.
#
# Per ADR-25 this gem is a pure RBS-bundle *plugin*: it ships a `sig/` directory and a trivial
# `Rigor::Plugin::Base` subclass whose manifest declares `signature_paths: ["sig"]`. Activate it by
# listing the gem under `.rigor.yml`'s `plugins:` — Rigor resolves and loads the bundled `sig/`
# automatically, with no hand-written path:
#
#     # .rigor.yml
#     plugins:
#       - rigor-activesupport-core-ext
#
# Coverage scope and rationale: see `README.md` in this directory and
# `docs/notes/20260515-real-world-rails-survey.md` for the survey that established the selector ranking.
require_relative "rigor/plugin/activesupport_core_ext"
