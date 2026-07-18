# frozen_string_literal: true

# rigor-rbs-inline — ingests rbs-inline-shaped comments (`# @rbs name: T`, `#: () -> T`, `# @rbs return: T`,
# attribute `#:`, ivars, generics, override, …) as RBS contributions to the analysis environment.
#
# Since ADR-93 WD1 the plugin defaults to `require_magic_comment: false`: annotations are official type
# sources wherever present, gated only on a file actually carrying one, with `# rbs_inline: disabled` the
# per-file opt-out. ADR-93 WD2 default-wires this plugin from `Configuration.load` when the upstream
# `rbs-inline` library is resolvable, so most projects need no `plugins:` entry at all. Restore the old
# ADR-32 magic-comment gate, or opt out of the auto-wire, through config:
#
#     # .rigor.yml
#     plugins:
#       - id: rigor-rbs-inline
#         config:
#           require_magic_comment: true    # default false — restore the ADR-32 magic-comment gate
#       # or disable the auto-wired default entirely:
#       # - gem: rigor-rbs-inline
#       #   enabled: false
#
# The plugin depends on the upstream `rbs-inline` gem; Rigor's core `rigortype` gemspec stays zero-dep per
# ADR-0 / ADR-32 WD1.
require_relative "rigor/plugin/rbs_inline"
