# frozen_string_literal: true

require "rigor/source/node_children"

require "prism"

module Rigor
  module Plugin
    class Pundit < Rigor::Plugin::Base
      # ADR-102 WD3 / #350 — which policy classes does this project's code actually *reach*?
      #
      # A Pundit policy is the textbook case for a plugin-supplied reachability root: `authorize @post` runs
      # `PostPolicy#update?`, and the string `PostPolicy` appears nowhere in the application. A reference
      # index therefore sees a live policy exactly as it sees a dead one, and `rigor unused` reports every
      # policy in the project as a candidate.
      #
      # **What this deliberately does NOT do is publish every class under `policy_search_paths`.** "A file
      # exists under `app/policies`" is not evidence that anything authorizes against it — it is the same
      # non-argument as "a file exists under `app/workers`". Rooting the whole directory would answer the
      # question by refusing to ask it, and an over-claiming root source silently hides real dead code
      # (ADR-102 § Consequences). So this walks the call sites instead and derives the policy each one names.
      #
      # Two derivations, both grounded in Pundit's own `PolicyFinder`, which builds the policy name from the
      # record's class:
      #
      # - a constant argument — `authorize Post`, `policy_scope(Post.all)` — names `PostPolicy` exactly;
      # - a receiverless name — `authorize @post` / `authorize post` — is camelized, because the Rails
      #   convention that names the carrier after the record is the same convention Pundit's lookup assumes.
      #
      # The camelization is a plain underscore split rather than `Rigor::Plugin::Inflector` (ADR-39), and the
      # reason it may be: the caller intersects every derived name with the policies {PolicyDiscoverer}
      # actually found, so a name this scan gets wrong matches nothing and is DROPPED. Inflection error can
      # only cost coverage here, never manufacture a root — which is the opposite of the direction ADR-39's
      # no-approximation rule is defending, where a wrong inflection becomes a wrong diagnostic.
      class AuthorizationScan
        # Pundit's entry points. `authorize` resolves and calls a predicate; `policy` and `policy_scope`
        # resolve without calling one. All three reach the policy class, which is what a root records.
        ENTRY_METHODS = %i[authorize policy policy_scope].freeze

        def initialize(io_boundary:, search_paths:)
          @io_boundary = io_boundary
          @search_paths = search_paths
        end

        # @return [Array<String>] policy class names named by an authorization call, sorted and unique. Not
        #   yet intersected with the discovered policies — the caller does that.
        def policy_names
          names = Set.new
          ruby_files_under(@search_paths).each do |path|
            contents = read_safely(path)
            next if contents.nil?

            parsed = Prism.parse(contents)
            next unless parsed.success?

            walk(parsed.value, names)
          end
          names.to_a.sort
        end

        private

        def read_safely(path)
          @io_boundary.read_file(path)
        rescue Plugin::AccessDeniedError, Errno::ENOENT
          nil
        end

        def ruby_files_under(roots)
          roots.flat_map do |root|
            absolute = File.expand_path(root)
            # ADR-45 WD1b (#613) — boundary-probed: a root that appears later invalidates the warm run.
            next [] unless @io_boundary.directory?(absolute)

            Dir.glob(File.join(absolute, "**", "*.rb"))
          end
        end

        def walk(node, names)
          return unless node.is_a?(Prism::Node)

          record_call(node, names) if node.is_a?(Prism::CallNode)
          node.rigor_each_child { |child| walk(child, names) }
        end

        def record_call(node, names)
          return unless ENTRY_METHODS.include?(node.name) && node.receiver.nil?

          record = node.arguments&.arguments&.first
          return if record.nil?

          name = policy_name_for(record)
          names << name if name
        end

        # @return [String, nil] the policy class the argument names, or nil when the argument is an
        #   expression this reading cannot attribute to a record (a method call with arguments, a literal, an
        #   index read). Silence, not a guess: an unattributable call contributes nothing.
        def policy_name_for(node)
          record = record_name_for(node)
          record && "#{record}Policy"
        end

        def record_name_for(node)
          case node
          when Prism::ConstantReadNode, Prism::ConstantPathNode then constant_name(node)
          when Prism::InstanceVariableReadNode then camelize(node.name.to_s.delete_prefix("@"))
          when Prism::LocalVariableReadNode then camelize(node.name.to_s)
          when Prism::CallNode then call_record_name(node)
          end
        end

        # `policy_scope(Post.all)` scopes `PostPolicy::Scope`, so the receiver constant is the record. A
        # receiverless bare name (`authorize post`) is the local-variable case Prism parses as a call when no
        # assignment made it a local — the memoised `def post` helper every Rails controller has.
        def call_record_name(node)
          return constant_name(node.receiver) if node.receiver.is_a?(Prism::ConstantReadNode) ||
                                                 node.receiver.is_a?(Prism::ConstantPathNode)
          return nil unless node.receiver.nil? && node.arguments.nil? && node.block.nil?

          camelize(node.name.to_s)
        end

        def camelize(token)
          return nil if token.empty? || !/\A[a-z_][a-z0-9_]*\z/.match?(token)

          token.split("_").reject(&:empty?).map { |part| part[0].upcase + part[1..].to_s }.join
        end

        def constant_name(node)
          case node
          when Prism::ConstantReadNode then node.name.to_s
          when Prism::ConstantPathNode then constant_path_name(node)
          end
        end

        def constant_path_name(node)
          parts = []
          current = node
          while current.is_a?(Prism::ConstantPathNode)
            parts.unshift(current.name.to_s)
            current = current.parent
          end
          case current
          when nil then parts.join("::")
          when Prism::ConstantReadNode then "#{current.name}::#{parts.join('::')}"
          end
        end
      end
    end
  end
end
