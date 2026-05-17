# frozen_string_literal: true

# Convenience entry point. `require "rigor-rails"` requires
# every Tier 1+2 Rails ecosystem plugin in one go, so projects
# that prefer a single require statement (some `spec_helper`
# patterns, ad-hoc scripts) do not have to list seven require
# lines.
#
# Note: requiring this entry point does NOT mark every plugin as
# active. The Rigor plugin loader walks `.rigor.yml`'s `plugins:`
# list and instantiates only the plugins enumerated there. This
# is per ADR-12 WD1's "Gemfile-convenience meta-gem" pattern —
# users still control which plugins participate in analysis via
# `.rigor.yml`.
#
# Sub-plugins ARE registered with `Rigor::Plugin` when this file
# loads (each gem's entry point side-effects a `Plugin.register`
# call); the loader's lookup phase finds them by id when listed.
#
# Adding the gem to a project's Gemfile without listing any
# plugin in `.rigor.yml` is harmless: the requires happen on
# `Bundler.require`, but no plugin's `init` / `prepare` / hooks
# run.

require "rigor-rails-routes"
require "rigor-rails-i18n"
require "rigor-actionmailer"
require "rigor-activejob"
require "rigor-activerecord"
require "rigor-actionpack"
require "rigor-factorybot"
