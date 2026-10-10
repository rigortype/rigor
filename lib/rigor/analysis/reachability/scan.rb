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
        # than a reference count (ADR-102 WD2). A reference in a declaration's own header — `class Sub < Base`,
        # `Sub = Class.new(Base)` — is credited to that declaration, while `nesting` stays the outer scope it
        # resolves in (#1720); that header case is the only one where `from` is not `nesting` joined. `role` is
        # the referring FILE's role (WD8). `rooted` is true when the constant was written with a leading `::`
        # (#625).
        Reference = Data.define(:as_written, :nesting, :from, :role, :path, :line, :rooted) do
          def initialize(rooted: false, **) = super
        end

        # ADR-102 WD4 — a site where a constant is reached by a mechanism the static reading cannot follow.
        # `name` is the exact constant when the argument is a literal (`"Foo".constantize`), in which case this
        # is as good as a reference. `prefix` is what a dynamic construction can reach, and `scope` says how
        # far — the two kinds of weak evidence are not the same shape:
        #
        # - `:namespace` — `"Foo::#{k}".constantize` can construct ANY name under `Foo`, so it taints `Foo`
        #   and every declaration beneath it. This is the default and the original meaning of `prefix`.
        # - `:exact` — a data-file or template match names ONE declaration and says nothing about its
        #   children (#370). `config/recurring.yml` mentioning `Admin` is not evidence about
        #   `Admin::CollectionPolicy`; treating it as such demoted 18 unrelated Mastodon rows off one
        #   Afrikaans word ("Administrasie" contains "Admin").
        DynamicUse = Data.define(:name, :prefix, :reason, :site, :path, :line, :scope) do
          def initialize(scope: :namespace, **) = super

          # Whether this site's evidence reaches `fqn`.
          def taints?(fqn)
            return false if prefix.nil?
            return fqn == prefix if scope == :exact

            fqn == prefix || fqn.start_with?("#{prefix}::")
          end
        end

        Result = Data.define(:declarations, :references, :dynamic_uses)

        # Roles a referring file can have (ADR-102 WD8). A reference edge carries its referrer's role so
        # "used only by its own test" is a reportable category rather than a bucket boundary.
        #
        # End-to-end suites (`qa/`, `e2e/`, GitLab's QA; `features/`, cucumber) are test code too (#1751). They
        # are matched at the project root only: `app/models/features/` is an ordinary namespace directory, and
        # a false :test would hide a production reference. Tooling directories (`rubocop/`, `keeps/`,
        # `tooling/`, `scripts/`) stay :production on purpose — deleting a class they use breaks the tooling.
        #
        # The role is decided from the path RELATIVE to `root` (the project root), never from the absolute
        # path: `/home/me/test/app/lib/a.rb` is not test code because a directory above the project is called
        # `test`. With no `root` the path is taken as already relative.
        def self.role_for(path, root: nil)
          path = relative_to(path, root)
          case path
          when %r{(\A|/)(spec|test)/}, /_(spec|test)\.rb\z/, %r{\A(\./)?(qa|e2e|features)/} then :test
          when /\.rake\z/, %r{(\A|/)(lib/)?tasks/} then :task
          when %r{(\A|/)config/} then :config
          else :production
          end
        end

        def self.relative_to(path, root)
          return path if root.nil?

          prefix = "#{root.to_s.chomp('/')}/"
          path.start_with?(prefix) ? path.delete_prefix(prefix) : path
        end
        private_class_method :relative_to

        # A constant name is ASCII by construction, so a byte sequence that is not valid UTF-8 cannot be one.
        # Dropping it is both correct and the only safe answer: carrying it forward crashed the whole run on
        # the first `String#sub` downstream, which is how this surfaced — `rigor unused` on Rigor's own
        # repository, which vendors a CRuby checkout containing deliberately ill-encoded encoding fixtures.
        def self.usable_name(raw)
          return nil if raw.nil?

          name = raw.dup.force_encoding(Encoding::UTF_8)
          name.valid_encoding? ? name : nil
        end

        # @param path — the file's path, as the report should render it.
        # @param source — the file's bytes.
        # @param target_ruby — Prism version string, threaded from the project configuration.
        # @param root — the project root `path` is made relative to when its role is decided.
        # @return nil when the file does not parse (a parse error is the analyzer's business, not
        #   this scan's — it simply contributes nothing rather than half a file).
        def self.call(path:, source:, target_ruby: nil, root: nil)
          parsed = if target_ruby
                     Prism.parse(source, filepath: path,
                                         version: target_ruby)
                   else
                     Prism.parse(source, filepath: path)
                   end
          return nil unless parsed.success?

          walker = Walker.new(path: path, role: role_for(path, root: root))
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
            # The declaration a meta-new rvalue is being walked for, or nil. See {#walk_constant_write}.
            @owner = nil
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
              walk_constant_write(node, nesting)
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
            # the OUTER nesting, not inside the body being opened. It is part of `Sub`'s declaration, though, so
            # it is credited to `Sub` (#1720): crediting the enclosing scope left a base nested in a module that
            # is never itself reached unreachable, and rooted a top-level base even when every subclass is dead.
            #
            # The superclass is WALKED, not only read as a name: `< DelegateClass(Foo)`, `< Struct.new(:a,
            # Foo::X)` and `< ActiveRecord::Migration[7.1]` are calls whose receiver and arguments name
            # constants, and reading only a constant node recorded none of them, so `Foo` was a false candidate
            # (#1733). Its references take the credit a meta-new rvalue's do.
            walk_owned(superclass, nesting, fqn) if superclass
            includes = node.body ? mixin_names(node.body) : []
            @declarations << Declaration.new(fqn: fqn, path: @path, line: node.location.start_line,
                                             superclass: superclass && Source::ConstantPath.qualified_name(superclass),
                                             includes: includes.freeze)
            return unless node.body

            # The body's nesting names the declaration itself, so a credit inherited from a meta-new rvalue
            # this declaration sits in must not leak into it.
            owner = @owner
            @owner = nil
            walk(node.body, nesting + [name])
            @owner = owner
          end

          # `Const = Class.new` / `Module.new` / `Data.define(...)` / `Struct.new(...)` declare a class under a
          # constant, and `ScopeIndexer#record_class_new_constant_decl` already treats them as class declarations
          # for cross-file resolution. The report must agree, or every such constant reads as an unreferenced
          # value rather than a class.
          META_NEW = { "Class" => :new, "Module" => :new, "Data" => :define, "Struct" => :new }.freeze
          private_constant :META_NEW

          # A meta-new rvalue — `Class.new(Base) { ... }`, `Struct.new(:a) do ... end` — is the declaration's
          # header and body, so the references in it are credited to the declared constant, exactly as a
          # `class Sub < Base` superclass is (#1720). Its lexical nesting is unchanged: a block opens no cref.
          def walk_constant_write(node, nesting)
            fqn = record_meta_new(node, nesting)
            return walk(node.value, nesting) if fqn.nil?

            walk_owned(node.value, nesting, fqn)
          end

          # Walks a declaration's header expression in the outer `nesting` it is evaluated in, crediting the
          # references in it to the declared `fqn`.
          def walk_owned(node, nesting, fqn)
            owner = @owner
            @owner = fqn
            walk(node, nesting)
            @owner = owner
          end

          # @return the declared FQN, or nil when the rvalue is not a meta-new form.
          def record_meta_new(node, nesting)
            call = node.value
            return unless call.is_a?(Prism::CallNode)

            recv = call.receiver
            return unless recv.is_a?(Prism::ConstantReadNode) && META_NEW[recv.name.to_s] == call.name

            fqn = (nesting + [node.name.to_s]).join("::")
            @declarations << Declaration.new(fqn: fqn, path: @path,
                                             line: node.location.start_line, superclass: nil, includes: [].freeze)
            fqn
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

            name, prefix = dynamic_target(subject)
            # A literal whose bytes are not valid UTF-8 cannot name a constant; dropping it is the only safe
            # answer, and carrying it forward crashed the whole run downstream.
            return if subject.is_a?(Prism::StringNode) && name.nil?
            return if subject.is_a?(Prism::SymbolNode) && name.nil?

            @dynamic_uses << DynamicUse.new(
              name: name, prefix: prefix, site: site(node), path: @path, line: node.location.start_line,
              reason: "#{node.name} on #{SUBJECT_SHAPES.fetch(subject.class, 'a computed value')}"
            )
          end

          # `[exact name, bounded namespace]` for a dynamic-resolution subject. A literal names its constant
          # exactly; an interpolation can only bound the namespace its literal head names; anything else bounds
          # nothing.
          def dynamic_target(subject)
            case subject
            when Prism::StringNode, Prism::SymbolNode then [Scan.usable_name(subject.unescaped), nil]
            when Prism::InterpolatedStringNode then [nil, literal_prefix(subject)]
            else [nil, nil]
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

            literal = Scan.usable_name(head.unescaped)
            return nil if literal.nil?

            trimmed = literal.sub(/::\z/, "")
            trimmed.empty? ? nil : trimmed
          end

          # `from` defaults to the innermost enclosing declaration; a declaration's own header (its superclass,
          # its meta-new rvalue) is credited to that declaration instead.
          def record_reference(node, nesting, from: @owner)
            as_written = Source::ConstantPath.qualified_name_or_nil(node)
            return if as_written.nil?

            from ||= nesting.empty? ? nil : nesting.join("::")
            @references << Reference.new(as_written: as_written, nesting: nesting.dup.freeze, from: from,
                                         role: @role, path: @path, line: node.location.start_line,
                                         rooted: Source::ConstantPath.rooted?(node))
          end
        end
      end
    end
  end
end
