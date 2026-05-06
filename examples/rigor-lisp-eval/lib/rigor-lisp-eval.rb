# frozen_string_literal: true

# Gem entry point. Required by Rigor's plugin loader when
# `.rigor.yml` lists `rigor-lisp-eval` under `plugins:`. The
# loader expects this `require` to side-effect a call to
# `Rigor::Plugin.register`, which the body of
# `lib/rigor/plugin/lisp_eval.rb` performs at load time.
require_relative "rigor/plugin/lisp_eval"
