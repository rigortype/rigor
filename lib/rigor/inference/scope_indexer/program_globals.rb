# frozen_string_literal: true

require "prism"

require_relative "../../scope"
require_relative "../../source/node_children"
require_relative "../../type"
require_relative "../error_info"
require_relative "../global_write_census"
require_relative "../in_effect_refinements"
require_relative "../last_line"
require_relative "../last_status"
require_relative "empty_seed"

module Rigor
  module Inference
    module ScopeIndexer
      # The program-global pre-pass of {ScopeIndexer#index}, moved out of `scope_indexer.rb` whole (ADR-116 WD9,
      # L4). {.seed_program_globals} collects the file's global writes and the censuses the same walk fills, joins
      # Ruby's own declarations into the seeds, and binds each global into the scope it is handed; every other
      # function here is a step of that. It calls nothing of the indexer but {EmptySeed}, a sibling file:
      # `scope_indexer.rb` requires this file, and this file does not require it back.
      module ProgramGlobals
        module_function

        # The program-global pre-pass's tables on the seeded scope's discovery index, and each global materialised into
        # the scope's own `globals` map (see the call site) — a declared one's seed ({#join_declared_globals}) under the
        # ADR-58 `:global` mark — with the `gets` / `readline` names the file patches in and whether it may set `$?` to
        # nil or define a singleton `===`.
        def seed_program_globals(root, seeded_scope)
          program_globals, census = build_program_global_index(root, seeded_scope)
          census[:discovered_global_write_census] =
            union_write_census(seeded_scope.discovered_global_write_census, census.delete(:write_census).census)
          seeds = join_declared_globals(program_globals, seeded_scope.environment)
          seeded_scope = seeded_scope.with_discovery(
            seeded_scope.discovery.with(program_globals: program_globals, program_global_seeds: seeds, **census)
          )
          program_globals.each do |name, written|
            seed = seeds[name]
            seeded_scope =
              seed ? seeded_scope.seed_declaration_sourced_global(name, seed) : seeded_scope.with_global(name, written)
          end
          seeded_scope
        end

        # Slice 7 phase 6 — program-global pre-pass. Globals are process-wide so the accumulator is a flat `Hash[Symbol,
        # Type::t]` populated from every `Prism::GlobalVariableWriteNode` in the program (top-level AND inside method
        # bodies). The same accumulator is seeded into every method body and the top-level scope.
        #
        # Issue #1359 — except the frame-local specials ({FRAME_LOCAL_GLOBALS}): Ruby keeps `$_` and `$~` in the slot
        # of the method, class, module or file body that writes them, so a write binds only that body and its blocks,
        # which the flow binding already carries, and every other body starts from its own slot.
        FRAME_LOCAL_GLOBALS = %i[$_ $~].freeze
        # Issue #1360 — nor `$!`, `$@` and `$?`, which hold no program-wide value either: the first two are the rescue
        # clause's that is running, and `$?` the thread's. Ruby refuses a write to `$!` or `$?` (`NameError`), and a
        # write to `$@` sets the backtrace of the exception being rescued.
        UNSEEDED_GLOBALS = (FRAME_LOCAL_GLOBALS + %i[$! $@ $?]).freeze
        private_constant :FRAME_LOCAL_GLOBALS, :UNSEEDED_GLOBALS

        #
        # The same walk collects the `gets` / `readline` names the file patches in through the `define_method` family
        # ({LastLine.patched_readers}), which it reaches in every node too, and whether the file holds a call that may
        # set `$?` to nil ({LastStatus.clears?}) or a `define_method` naming `===` ({ErrorInfo.defines_case_equality?}).
        # Issue #1415 — the census also carries the file's evidence about the `self` of its implicit-self readers
        # ({LastLine::SelfEvidence}), which walks the file only when a reader condition first asks. Issue #1367 — and
        # the file's {GlobalWriteCensus}, which the `global.*` write rules read.
        # @return the `program_globals` table and the census, keyed by the discovery index members it fills
        def build_program_global_index(root, default_scope)
          accumulator = {}
          in_effect = InEffectRefinements.new(root)
          census = { patched_line_readers: Set.new, clears_last_status: false, defines_case_equality: false,
                     write_census: GlobalWriteCensus::Collector.new(in_effect) }
          gather_global_writes(root, default_scope, accumulator, census)
          census[:patched_line_readers] = census[:patched_line_readers].freeze
          census[:implicit_self_evidence] = LastLine::SelfEvidence.new(root)
          census[:in_effect_refinements] = in_effect
          [accumulator.freeze, census]
        end

        # Issue #1362 (ADR-117 WD1) — the seed of each global in `program_globals` Ruby's own signatures declare
        # (`$VERBOSE: bool?`, `$stdout: IO`). Such a global holds what the interpreter set, from the command line or at
        # boot, until a write, and any loaded file may write it, so its seed is the declared type joined with the file's
        # writes, which can only widen it: `$VERBOSE = true` seeds `bool`, and `$stdout = StringIO.new` seeds
        # `IO | StringIO`. A global only a project or a gem declares, or none does, has no entry here and is seeded with
        # the union of the file's writes, as before, and so is a separator ({UNJOINED_SEPARATORS}).
        #
        # Issue #1437 — the declared `nil` is not joined (`$VERBOSE` joins `bool`, not `bool?`): a value that mixes the
        # global with something else (`c ? $VERBOSE : true`) would carry it past the ADR-58 mark into a report the
        # file's writes did not earn. A `nil` the file writes is joined as any write is.
        def join_declared_globals(program_globals, environment)
          program_globals.each_with_object({}) do |(name, written), seeds|
            next if UNJOINED_SEPARATORS.include?(name)

            declared = non_nil_declared(environment.global_for_name(name, builtin: true))
            seeds[name] = Type::Combinator.union(declared, written) if declared
          end.freeze
        end

        # `declared` without its `nil` member, or nil when it has no other.
        def non_nil_declared(declared)
          return declared unless declared.is_a?(Type::Union) || nil_type?(declared)

          members = declared.is_a?(Type::Union) ? declared.members.reject { |member| nil_type?(member) } : []
          members.empty? ? nil : Type::Combinator.union(*members)
        end

        def nil_type?(type)
          (type.is_a?(Type::Constant) && type.value.nil?) ||
            (type.is_a?(Type::Nominal) && type.class_name == "NilClass")
        end

        # Issue #1437 — the separators whose declared type is nil-bearing (`String?`, `Regexp | String | nil`) stay out
        # of the join for now. The declared `nil` would reach `call.possible-nil-receiver` through a value that mixes
        # the global with something else (`sep = c ? $/ : ";"`, `sep = given || $/`), which the ADR-58 mark does not
        # follow.
        UNJOINED_SEPARATORS = %i[$/ $, $; $\\ $-0 $-F $-i].freeze
        private_constant :UNJOINED_SEPARATORS

        # `top_level` is false inside a `class` / `module` body, for the census's top-level mixins.
        def gather_global_writes(node, scope, accumulator, census, top_level: true)
          return unless node.is_a?(Prism::Node)

          if node.is_a?(Prism::GlobalVariableWriteNode) && !UNSEEDED_GLOBALS.include?(node.name)
            record_global_write(node, scope, accumulator)
          end
          readers = LastLine.patched_readers(node)
          census[:patched_line_readers].merge(readers) if readers
          census[:clears_last_status] ||= LastStatus.clears?(node)
          census[:defines_case_equality] ||= ErrorInfo.defines_case_equality?(node)
          census[:write_census].visit(node, top_level: top_level)
          inner = top_level && !(node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode))
          node.rigor_each_child { |c| gather_global_writes(c, scope, accumulator, census, top_level: inner) }
        end

        # The project's census with the analysed file's own, answering `seed` itself when the file adds nothing to it.
        def union_write_census(seed, file_census)
          return seed if file_census.empty? || file_census.subset?(seed)

          (seed | file_census).freeze
        end

        def record_global_write(node, scope, accumulator)
          rvalue_type = EmptySeed.erase(node.value, scope.type_of(node.value))
          existing = accumulator[node.name]
          accumulator[node.name] =
            existing ? Type::Combinator.union(existing, rvalue_type) : rvalue_type
        end

        private_class_method :build_program_global_index, :join_declared_globals, :non_nil_declared, :nil_type?,
                             :gather_global_writes, :union_write_census, :record_global_write
      end
    end
  end
end
