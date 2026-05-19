# frozen_string_literal: true

# rigor-activesupport-core-ext — a community-maintained RBS bundle for
# the most-frequently-flagged ActiveSupport core extensions.
#
# This gem ships RBS files only; there is no analyzer-side plugin
# code. Wire the gem into a project by adding its `sig/` directory
# to `.rigor.yml`'s `signature_paths:`:
#
#     # .rigor.yml
#     signature_paths:
#       - sig
#       - path/to/rigor-activesupport-core-ext/sig
#
# Or, when consumed directly from a Bundler context:
#
#     # .rigor.yml
#     signature_paths:
#       - sig
#       - <%= Gem.loaded_specs["rigor-activesupport-core-ext"].full_gem_path %>/sig
#
# Coverage scope and rationale: see `README.md` in this directory and
# `docs/notes/20260515-real-world-rails-survey.md` for the survey
# that established the selector ranking.
