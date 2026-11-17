# frozen_string_literal: true

module Rigor
  module Inference
    # Issue #3282 — an external chain entry the PROJECT declares, whose every declaring body was read, and which
    # wrote nothing under the name a reader is looking up. {DefinerResolution}'s external rule declines a read that
    # passes an external entry, because an ancestor RBS does not know may be the definer Ruby calls. That is right
    # for a gem module whose source nobody read. It is wrong for a module whose body the project itself walked.
    #
    # A project module with no `def` of its own is an external entry by construction (#2094, and #3156's
    # {Scope::ResolutionChain::Entry#declared_name} names it). That cost a pin rather than correctness until a
    # concern's whole body became an `included do` block. Mastodon's `Paginable` is exactly that shape — two
    # `scope` calls and a `def self.to_a_paginated_by_id`, all inside the block — so once #3015 correctly stopped
    # filing the block's `def self.x` on the concern, the module recorded nothing of its own, became an external
    # entry, and declined every instance read on the twenty-odd models that include it: `Account#followed_by?`,
    # `#suspended?`, `#unavailable?`, `#silenced?` and 18 more pairs typed `Dynamic`. The engine was disbelieving
    # a body it had already read.
    #
    # Each clause closes one way the module could still answer, and every one must hold:
    #
    #   1. `declared_name` is non-nil: a `discovered_classes` key that is not a class WITH a body, that no project
    #      constant write binds, and that RBS does not know. An RBS-known name keeps declining, because RBS speaks
    #      for a surface the project did not write.
    #   2. `discovered_class_sources` holds the name: a WHOLE-PROJECT pass filed the files that declare it. A
    #      single-file index (`run_source`, the LSP `prebuilt:` scope) files none, so it never skips — there, a
    #      reopening in another file is exactly what cannot be ruled out.
    #   3. The bucket does not {Scope::DiscoveryIndex.rewritten_surface?}: no `class_eval`, computed
    #      `define_method`, `send` or `refine` rewrites its table under a name no argument spells.
    #   4. The bucket carries no open-names mark for the side (`Struct.new(*FIELDS)`, `attr_accessor(*NAMES)`),
    #      which says this side holds names no table spells.
    #   5. No `[side, name]` envelope entry and no recorded `def` names it. The envelope clause is what keeps a
    #      concern honest: `Paginable`'s bucket DOES hold `[:instance, :paginate_by_max_id]` for what its hook
    #      block defines, so a read of THAT name still declines here, and is answered on the includer through the
    #      `<included>` entry the chain holds separately.
    #
    # The skip rests on negative facts and files an edge for each: `declared_name` files the module's own negative
    # class and constant edges, and clause 5's def read goes through `Scope#user_def_for` / `#singleton_def_for`,
    # which record the cross-file method edge on a miss. So a `def` appearing for the name, in this module or any
    # other file, re-runs the reader under `--incremental`.
    module BodyReadExternal
      module_function

      # Whether `entry` is such an entry for `method_name`: the project read its body, and the body lacks the name.
      def lacks?(scope, entry, method_name)
        declared = entry.declared_name(scope)
        return false if declared.nil?
        return false unless scope.discovered_class_sources.key?(declared)

        bucket = scope.parameter_envelopes_of(declared)
        return false if Scope::DiscoveryIndex.rewritten_surface?(bucket)
        return false if Scope::DiscoveryIndex.open_names_on?(bucket, entry.side)
        return false if bucket.key?([entry.side, method_name.to_sym])

        own_def(scope, declared, entry.side, method_name).nil?
      end

      def own_def(scope, class_name, side, method_name)
        return scope.singleton_def_for(class_name, method_name) if side == :singleton

        scope.user_def_for(class_name, method_name)
      end
    end
  end
end
