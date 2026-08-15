# frozen_string_literal: true

require "prism"

require_relative "../../source/constant_path"
require_relative "../../source/node_children"

module Rigor
  module Analysis
    module Reachability
      # ADR-102 — the per-file half of the reference index: one Prism walk that records every constant
      # DECLARATION and every constant REFERENCE, each with the lexical nesting in force at that point.
      #
      # This is deliberately NOT a hook on the typing path. `Reflection.resolve_constant_type` fires only where
      # the engine needs a constant's *type*, so a constant that is read but never typed leaves no trace there —
      # the #345 measurement found five distinct losses (cross-file value constants, parameter defaults,
      # lambda-rvalue bodies, superclass positions, intermediate namespace segments) and produced 140 candidates
      # of which zero were genuine. A reference index has to see every constant node regardless of whether a type
      # was wanted, which is what this walk does.
      #
      # Names are recorded AS WRITTEN together with their nesting; resolution to a fully-qualified name happens
      # in {Graph}, after every file has been scanned, because a bare `Foo` cannot be resolved until the whole
      # declaration set is known.
      module Scan
        # A class / module declaration, or a constant assigned one of the meta-new forms. `nesting` is the
        # enclosing declaration path at the declaration site, so `fqn` is exact.
        Declaration = Data.define(:fqn, :path, :line, :superclass, :includes)

        # One constant reference. `from` is the fully-qualified name of the innermost enclosing declaration, or
        # nil for a reference written at file level — that is what makes the graph a reachability graph rather
        # than a reference count (ADR-102 WD2). `role` is the referring FILE's role (WD8).
        Reference = Data.define(:as_written, :nesting, :from, :role, :path, :line)

        # ADR-102 WD4 — a site where a constant is reached by a mechanism the static reading cannot follow.
        # `name` is the exact constant when the argument is a literal (`"Foo".constantize`), in which case this
        # is as good as a reference. `prefix` is the namespace a dynamic construction can reach into
        # (`"Foo::#{k}".constantize` → `"Foo"`, and `nil` when even that is unknown), which taints every
        # declaration at or below it rather than proving any single one used.
        DynamicUse = Data.define(:name, :prefix, :reason, :site, :path, :line)

        Result = Data.define(:declarations, :references, :dynamic_uses)

        # Roles a referring file can have (ADR-102 WD8). A reference edge carries its referrer's role so
        # "used only by its own test" is a reportable category rather than a bucket boundary.
        def self.role_for(path)
          case path
          when %r{(\A|/)(spec|test)/}, /_(spec|test)\.rb\z/ then :test
          when /\.rake\z/, %r{(\A|/)(lib/)?tasks/} then :task
          when %r{(\A|/)config/} then :config
          else :production
          end
        end

        # @param path [String] the file's path, as the report should render it.
        # @param source [String] the file's bytes.
        # @param target_ruby [String, nil] Prism version string, threaded from the project configuration.
        # @return [Result, nil] nil when the file does not parse (a parse error is the analyzer's business, not
        #   this scan's — it simply contributes nothing rather than half a file).
        def self.call(path:, source:, target_ruby: nil)
          parsed = if target_ruby
                     Prism.parse(source, filepath: path,
                                         version: target_ruby)
                   else
                     Prism.parse(source, filepath: path)
                   end
          return nil unless parsed.success?

          walker = Walker.new(path: path, role: role_for(path))
          walker.walk(parsed.value, [])
          Result.new(declarations: walker.declarations.freeze, references: walker.references.freeze,
                     dynamic_uses: walker.dynamic_uses.freeze)
        end

        # Single-pass walker. Tracks `nesting` as the stack of enclosing declaration names.
        class Walker
          attr_reader :declarations, :references, :dynamic_uses

          def initialize(path:, role:)
            @path = path
            @role = role
            @declarations = []
            @references = []
            @dynamic_uses = []
          end

          def walk(node, nesting)
            return unless node.is_a?(Prism::Node)

            case node
            when Prism::ClassNode  then return walk_declaration(node, nesting, superclass: node.superclass)
            when Prism::ModuleNode then return walk_declaration(node, nesting, superclass: nil)
            when Prism::ConstantReadNode, Prism::ConstantPathNode
              record_reference(node, nesting)
              # A constant path's segments are not separate references — `A::B::C` is one reference to the leaf,
              # and descending would record `A` and `A::B` as references in their own right (22 spurious
              # candidates on Rigor's own lib came from exactly that in the #345 probe).
              return
            when Prism::ConstantWriteNode
              record_meta_new(node, nesting)
              walk(node.value, nesting)
              return
            when Prism::CallNode
              record_dynamic_use(node)
            end

            node.rigor_each_child { |child| walk(child, nesting) }
          end

          private

          def walk_declaration(node, nesting, superclass:)
            name = Source::ConstantPath.qualified_name(node.constant_path)
            return node.rigor_each_child { |child| walk(child, nesting) } if name.nil?

            fqn = (nesting + [name]).join("::")
            # The superclass position IS a reference — `class Sub < Base` reads `Base` — and it resolves against
            # the OUTER nesting, not inside the body being opened.
            record_reference(superclass, nesting) if superclass
            includes = node.body ? mixin_names(node.body) : []
            @declarations << Declaration.new(fqn: fqn, path: @path, line: node.location.start_line,
                                             superclass: superclass && Source::ConstantPath.qualified_name(superclass),
                                             includes: includes.freeze)
            walk(node.body, nesting + [name]) if node.body
          end

          # `Const = Class.new` / `Module.new` / `Data.define(...)` / `Struct.new(...)` declare a class under a
          # constant, and `ScopeIndexer#record_class_new_constant_decl` already treats them as class declarations
          # for cross-file resolution. The report must agree, or every such constant reads as an unreferenced
          # value rather than a class.
          META_NEW = { "Class" => :new, "Module" => :new, "Data" => :define, "Struct" => :new }.freeze
          private_constant :META_NEW

          def record_meta_new(node, nesting)
            call = node.value
            return unless call.is_a?(Prism::CallNode)

            recv = call.receiver
            return unless recv.is_a?(Prism::ConstantReadNode) && META_NEW[recv.name.to_s] == call.name

            @declarations << Declaration.new(fqn: (nesting + [node.name.to_s]).join("::"), path: @path,
                                             line: node.location.start_line, superclass: nil, includes: [].freeze)
          end

          # `include` / `prepend` / `extend` argument names written directly in the declaration body. Only the
          # top level of the body is inspected: a mixin applied inside a conditional or a nested def is not a
          # static ancestor edge.
          def mixin_names(body)
            body.child_nodes.filter_map do |stmt|
              next unless stmt.is_a?(Prism::CallNode) && %i[include prepend extend].include?(stmt.name)
              next if stmt.receiver

              arg = stmt.arguments&.arguments&.first
              arg && Source::ConstantPath.qualified_name_or_nil(arg)
            end
          end

          # Names that turn a String into a constant. `constantize` / `safe_constantize` are ActiveSupport;
          # `const_get` is core and may carry an explicit receiver (`Object.const_get`, `self.class.const_get`).
          DYNAMIC_RESOLVERS = %i[constantize safe_constantize const_get].freeze
          private_constant :DYNAMIC_RESOLVERS

          SUBJECT_SHAPES = {
            Prism::StringNode => "a literal string",
            Prism::SymbolNode => "a literal symbol",
            Prism::InterpolatedStringNode => "an interpolated string"
          }.freeze
          private_constant :SUBJECT_SHAPES

          # Rigor knows the argument's shape, which is the whole reason this can be tiered rather than treated
          # as a blanket namespace poison: a literal argument names the exact constant and is as good as a
          # written reference, while an interpolated one can only bound the namespace it reaches into.
          def record_dynamic_use(node)
            return unless DYNAMIC_RESOLVERS.include?(node.name)

            subject = node.name == :const_get ? node.arguments&.arguments&.first : node.receiver
            return if subject.nil?

            reason = "#{node.name} on #{SUBJECT_SHAPES.fetch(subject.class, 'a computed value')}"
            case subject
            when Prism::StringNode, Prism::SymbolNode
              @dynamic_uses << DynamicUse.new(name: subject.unescaped, prefix: nil, reason: reason,
                                              site: site(node), path: @path, line: node.location.start_line)
            when Prism::InterpolatedStringNode
              @dynamic_uses << DynamicUse.new(name: nil, prefix: literal_prefix(subject), reason: reason,
                                              site: site(node), path: @path, line: node.location.start_line)
            else
              @dynamic_uses << DynamicUse.new(name: nil, prefix: nil, reason: reason,
                                              site: site(node), path: @path, line: node.location.start_line)
            end
          end

          # The literal head of an interpolated name: `"Foo::Bar::#{k}"` bounds the reach to `Foo::Bar`. Returns
          # nil when the interpolation starts the string, which bounds nothing.
          def site(node)
            "#{@path}:#{node.location.start_line}"
          end

          def literal_prefix(node)
            head = node.parts.first
            return nil unless head.is_a?(Prism::StringNode)

            trimmed = head.unescaped.sub(/::\z/, "")
            trimmed.empty? ? nil : trimmed
          end

          def record_reference(node, nesting)
            as_written = Source::ConstantPath.qualified_name_or_nil(node)
            return if as_written.nil?

            @references << Reference.new(as_written: as_written, nesting: nesting.dup.freeze,
                                         from: nesting.empty? ? nil : nesting.join("::"),
                                         role: @role, path: @path, line: node.location.start_line)
          end
        end
      end
    end
  end
end
