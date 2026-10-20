# frozen_string_literal: true

require "prism"

module Rigor
  module Analysis
    # Issue #2021 — the files a run analyses outside the configured `paths:` load through `require_relative`.
    #
    # A run over path arguments widens its discovery to the configured paths (#684), which is the whole project for
    # a file inside them. A file outside them has no such project: `rigor check plugins/x/lib/rigor/plugin/x.rb`
    # in a repository whose `paths:` is `lib` discovered `x.rb` and `lib` alone. The plugin's nested `Effects`,
    # declared in the sibling `x/effects.rb`, was then invisible, the lexical lookup fell through to the
    # project's `Rigor::Effects`, and every call on it drew a false `call.undefined-method` that checking the
    # plugin's `lib` did not.
    #
    # The file names its siblings itself: Ruby loads what it `require_relative`s before any of its code runs, so
    # those declarations are in scope at runtime. {.closure} follows that graph from the out-of-paths files,
    # through each target that is itself outside the configured paths. A target under a configured path is
    # already discovered and stops the walk there, so the files inside `paths:` are discovered exactly as a run
    # over the configured paths discovers them. Only a string literal counts (`require_relative "a/b"`, with or
    # without the `.rb`); a computed name, `require`, `load` and `autoload` are not followed, so a gem's own
    # files and a Zeitwerk-loaded tree are not reached this way.
    #
    # The walk sees one entry point's load graph, and a file it does not reach may redefine what a walked file
    # defines. The runner therefore discovers the walked files as uncertain: their declarations resolve constants
    # and their methods exist, but no return type, arity or visibility is read from them.
    module RequireRelativeClosure
      # The walk's answer: the existing targets it reached, and the targets it named that are not files (each an
      # input of the answer too, since one appearing would join the discovery).
      Result = Data.define(:found, :missing)

      module_function

      # @param seeds — the analysed files outside the configured paths, as spelled by the run.
      # @param covered — `->(real_path) { Boolean }`, whether a target lies under a configured path, where discovery
      #   holds it already. The walk neither adds nor follows such a target. Paths are compared as real paths, so a
      #   symlinked spelling of a configured file is covered too.
      # @param read — `->(path) { String }`, the source of a file (an editor buffer's bytes for its file).
      # @return a {Result}; `found` holds absolute paths in walk order, each file once, and never a seed.
      def closure(seeds, covered:, read:)
        seen = seeds.to_set { |path| real_path(path) }
        queue = seeds.dup
        found = []
        missing = []
        until queue.empty?
          targets_of(queue.shift, read).each do |target|
            next missing << target unless File.file?(target)

            real = real_path(target)
            next if covered.call(real) || !seen.add?(real)

            found << target
            queue << target
          end
        end
        Result.new(found: found, missing: missing.uniq)
      end

      def real_path(path)
        File.realpath(path)
      rescue SystemCallError
        File.absolute_path(path)
      end

      # The `.rb` paths `path` names with a literal `require_relative`, absolute, whether or not they exist.
      def targets_of(path, read)
        source = read.call(path)
        return [] if source.nil?

        base = File.dirname(File.absolute_path(path))
        literal_features(Prism.parse(source).value).map do |feature|
          File.expand_path(feature.end_with?(".rb") ? feature : "#{feature}.rb", base)
        end
      rescue StandardError
        []
      end

      # In source order, so discovery meets the targets in the order Ruby loads them.
      def literal_features(root)
        calls = []
        stack = [root]
        until stack.empty?
          node = stack.pop
          calls << node if literal_feature(node)
          stack.concat(node.compact_child_nodes)
        end
        calls.sort_by { |call| call.location.start_offset }.filter_map { |call| literal_feature(call) }
      end

      def literal_feature(node)
        return nil unless node.is_a?(Prism::CallNode) && node.name == :require_relative && node.receiver.nil?

        arguments = node.arguments&.arguments
        return nil unless arguments&.size == 1 && arguments.first.is_a?(Prism::StringNode)

        arguments.first.unescaped
      end
    end
  end
end
