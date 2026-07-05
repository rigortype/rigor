# frozen_string_literal: true

# rigor-rbs-inline — ingests rbs-inline-shaped comments (`# @rbs name: T`, `#: () -> T`, `# @rbs return: T`,
# attribute `#:`, ivars, generics, override, …) as RBS contributions to the analysis environment.
#
# Per ADR-32 the plugin gates per file on the upstream `# rbs_inline: enabled` magic comment by default. A
# host context that owns the entire analysis scope (e.g. the ADR-29 browser playground) can set
# `require_magic_comment: false` in the plugin config to skip the gate — every file the synthesizer sees is
# treated as if it carried the magic comment.
#
#     # .rigor.yml
#     plugins:
#       - id: rigor-rbs-inline
#         config:
#           require_magic_comment: false   # default true
#
# The plugin depends on the upstream `rbs-inline` gem; Rigor's core `rigortype` gemspec stays zero-dep per
# ADR-0 / ADR-32 WD1.
require_relative "rigor/plugin/rbs_inline"
