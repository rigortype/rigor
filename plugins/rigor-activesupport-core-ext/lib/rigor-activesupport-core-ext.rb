# frozen_string_literal: true

# rigor-activesupport-core-ext — a community-maintained RBS bundle for
# the most-frequently-flagged ActiveSupport core extensions.
#
# This gem ships RBS files only; there is no analyzer-side plugin
# code. Wire the gem into a project by adding its `sig/` directory
# to `.rigor.yml`'s `signature_paths:`. Those entries are plain
# directory paths — `.rigor.yml` is parsed with `YAML.safe_load_file`
# and is NOT ERB-rendered, so embedded Ruby cannot be used.
#
# Point at the installed gem's `sig/` (locate it with
# `bundle show rigor-activesupport-core-ext`):
#
#     # .rigor.yml
#     signature_paths:
#       - sig
#       - /absolute/path/to/rigor-activesupport-core-ext/sig
#
# Or, for a version-stable and portable setup, vendor this bundle's
# `sig/` directory into the project and use a relative path:
#
#     # .rigor.yml
#     signature_paths:
#       - sig
#       - vendor/rigor-activesupport-core-ext-sig
#
# Coverage scope and rationale: see `README.md` in this directory and
# `docs/notes/20260515-real-world-rails-survey.md` for the survey
# that established the selector ranking.
