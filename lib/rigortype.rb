# frozen_string_literal: true

# Nothing in an application should ever load Rigor: it is a command-line tool
# that reads a project from the outside, not a library (ADR-27). This file
# exists only because `Bundler.require` — the default for every Gemfile entry,
# and what Rails runs at boot — requires a gem by its *gem* name, `rigortype`,
# while the library entry point is `rigor.rb`.
#
# Without this file that call raises a bare `LoadError` naming `rigortype`, so
# a `bundle add rigortype` succeeds and the *next* `rails s` dies with no
# explanation of what went wrong or what to do instead. The file is a guardrail,
# not an entry point: it warns and defines nothing. `require "rigor"` remains
# the (analyzer-internal) way in.
warn(<<~MESSAGE)
  rigortype: `require "rigortype"` does nothing — Rigor is a command-line tool, not a library.

  This usually means Rigor is in your Gemfile, where `Bundler.require` loads it at boot. Rigor
  analyses your project from the outside and runs on its own Ruby, so a Gemfile entry constrains
  your application's Ruby and dependency resolution without giving you anything. Remove it and
  install Rigor independently: https://github.com/rigortype/rigor/blob/master/docs/install.md

  To keep the Gemfile entry anyway, mark it `gem "rigortype", require: false` — that silences
  this warning, but the resolution constraints remain.
MESSAGE
