# frozen_string_literal: true

# The Tier 1+2 Rails set, as a single require. Requiring this file registers every member class with
# `Rigor::Plugin`; the loader's lookup phase then finds them by id when `.rigor.yml` enumerates them.
#
# UNWIRED — this entry point has no supported use today, and is kept deliberately (ADR-96 WD5) rather
# than removed. It was ADR-12 WD1's "Gemfile-convenience meta-gem": each plugin was to be its own gem, and
# `gem "rigor-rails"` was to pull the Rails set into a project's Gemfile in one line. Commit `9769f5fa`
# dropped the per-plugin gemspecs and ADR-31 settled distribution on the single bundled `rigortype` gem, so
# there is no `rigor-rails` gem to add to a Gemfile — and `plugins: [rigor-rails]` is rejected by the
# loader, which requires the members to be enumerated (or one selected with an explicit `id:`).
#
# ADR-96 WD3 proposes the role this file would fill: `plugins: [rigor-rails]` activating those members
# whose `target_gems:` are actually in the project's `Gemfile.lock`. If that is rejected, ADR-60 WD1's
# never-wired-surface criterion applies and this directory goes.

require "rigor-railties"
require "rigor-rails-routes"
require "rigor-rails-i18n"
require "rigor-actionmailer"
require "rigor-activejob"
require "rigor-activerecord"
require "rigor-actionpack"
require "rigor-factorybot"
