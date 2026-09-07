# frozen_string_literal: true

require "prism"

require_relative "../../inference/version_guard"
require_relative "../../source/node_children"

module Rigor
  module Analysis
    module CheckRules
      # ADR-47 WD5 — drops the diagnostics that land inside the **dead arm of a decidable version guard**
      # (issue #627).
      #
      # {Inference::StatementEvaluator} already skips evaluating that arm, so its writes never join into the
      # post-`if` scope. Skipping the evaluation is not by itself enough to silence the arm, though: the
      # rule walk visits every node of the file whether or not the evaluator typed it, so a call whose
      # receiver is typeable on its own — a constant, a literal — still reports. `mail/lib/mail/yaml.rb`'s
      #
      #     ::YAML.safe_load(yaml, permitted_classes)   # the Psych < 3.1 positional form
      #
      # is exactly that shape: honest against the Ruby 4 Psych signature, and unreachable on the Ruby the
      # user is checking with. This is the second half of the fix — the arm stops producing diagnostics.
      #
      # The dead arms are found by re-asking {Inference::VersionGuard}, which is a pure function of the AST,
      # so this filter and the evaluator's arm elision cannot disagree about which arm is dead.
      #
      # Applied to the type / flow rules only, and BEFORE `suppression.*` joins the list: a malformed
      # `# rigor:disable` marker inside a dead arm is still a real authoring error — the marker's own
      # well-formedness does not depend on whether the code around it runs.
      module DeadVersionGuardArms
        module_function

        def filter(diagnostics, root)
          # The scan is a whole-file walk, so it is paid only when there is something to drop. A file with
          # no diagnostics — the overwhelming majority — never walks.
          return diagnostics if diagnostics.empty?

          arms = scan(root)
          return diagnostics if arms.empty?

          diagnostics.reject { |diagnostic| arms.any? { |arm| covers?(arm, diagnostic) } }
        end

        # @rbs return: Array[Prism::Location] -- The source ranges of every dead version-guard arm
        def scan(root)
          arms = []
          collect(root, arms)
          arms
        end

        def collect(node, arms)
          return unless node.is_a?(Prism::Node)

          dead = dead_arm(node)
          arms << dead.location if dead
          # Nothing inside a dead arm can produce a surviving diagnostic, so the walk does not descend into
          # it — a nested guard there would only add a range already covered.
          node.rigor_each_child { |child| collect(child, arms) unless dead && child.equal?(dead) }
        end
        private_class_method :collect

        # The arm that cannot run, or nil when the guard is undecidable (both arms live — the pre-existing
        # behaviour) or the dead arm is absent (`foo if RUBY_VERSION >= "3.1"` has no `else`).
        def dead_arm(node)
          case node
          when Prism::IfNode
            case Inference::VersionGuard.verdict(node.predicate)
            when :truthy then node.subsequent
            when :falsey then node.statements
            end
          when Prism::UnlessNode
            # `unless` runs its body on the FALSEY edge, so the arms are swapped.
            case Inference::VersionGuard.verdict(node.predicate)
            when :truthy then node.statements
            when :falsey then node.else_clause
            end
          end
        end
        private_class_method :dead_arm

        # Prism columns are 0-based and `Diagnostic#column` is 1-based; the location's end is exclusive.
        # Compared as `[line, column]` pairs rather than by line alone so a one-line guard
        # (`RUBY_VERSION >= "3.1" ? a(1) : a(1, 2)`) drops only the dead half.
        def covers?(location, diagnostic)
          position = [diagnostic.line, diagnostic.column - 1]
          return false if (position <=> [location.start_line, location.start_column]).negative?

          (position <=> [location.end_line, location.end_column]).negative?
        end
        private_class_method :covers?
      end
    end
  end
end
