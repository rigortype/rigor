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
        # - `:leading` — `"V#{version}"` is the START of a name, not a namespace, so it can construct `V1_0`
        #   and `V2_2` as well as anything beneath them: a string-prefix match (#1734).
        #
        # `within` is set for a `const_get` on a known receiver — `Foo.const_get("Bar::#{k}")`, or an implicit
        # receiver, `self` or `self.class`, which is the enclosing declaration written rooted: `prefix` is then
        # relative to the receiver, a {Reference} that {Graph} resolves as it resolves any other before
        # matching. A literal `name` keeps `within` too, and {Graph} looks it up from there (#1761). `inherit`
        # is false when the call passes `inherit = false`, which confines the lookup to the receiver itself;
        # otherwise the receiver's ancestors are searched as well. `role` is the referring file's (WD8).
        #
        # `receiver_open` is true when `within` is the enclosing declaration standing for a runtime `self` that
        # may be one of its descendants (#1878): a `def self.x = const_get(:X)` runs on whichever subclass it
        # is called on, and a module's method on whichever class includes, prepends or extends it. {Graph}
        # then looks the literal name up in those descendants as well.
        #
        # `anywhere` is true when the receiver is a `self` the walk cannot name at all — the block of an eval call
        # on a local or another computed receiver (`k.class_eval { const_get(:E) }`, #1946). {Graph} then keeps
        # every declaration the literal could name.
        DynamicUse = Data.define(:name, :prefix, :reason, :site, :path, :line, :scope, :within, :inherit, :role,
                                 :receiver_open, :anywhere) do
          def initialize(scope: :namespace, within: nil, inherit: true, role: :production, receiver_open: false,
                         anywhere: false, **)
            super
          end

          # Whether this site's evidence reaches `fqn`.
          def taints?(fqn)
            return false if prefix.nil?
            return fqn == prefix if scope == :exact
            return fqn.start_with?(prefix) if scope == :leading

            fqn == prefix || fqn.start_with?("#{prefix}::")
          end

          # The namespaces an interpolated site's `within` names, resolved by the block. A resolution of the whole
          # written path is the anchor. {Graph#resolve} peels an unknown `Foo::Bar` to `Foo`, though, and
          # anchoring there alone looked for `Foo::V*` and missed `Foo::Bar::V1`; the written name is then an
          # anchor as well as the peeled one, since an undeclared receiver may be an alias of either. A receiver
          # that does not resolve at all keeps its written name. Over-reaching is safe for a taint only; a
          # literal anchors at {#receiver} alone.
          def anchors
            resolved = yield(within)
            whole?(resolved) ? [resolved] : [within.as_written, resolved].compact
          end

          # The declaration `within` names when it resolves as WHOLE, or nil. A receiver resolved only by peeling
          # its last segment is unknown: `const_get` never searches the receiver's lexical parent, so anchoring a
          # literal there could resolve it to a dead constant and miss the live one.
          def receiver
            resolved = yield(within)
            whole?(resolved) ? resolved : nil
          end

          def whole?(resolved)
            written = within.as_written
            resolved == written || resolved&.end_with?("::#{written}")
          end
        end

        # An ancestry edge written outside a declaration's header and body statements (#1946): `K.include(Mix)`,
        # `K.send(:include, Mix)` and the `prepend` / `extend` / `public_send` / `__send__` forms, an `include`
        # in an eval block on `K` or nested in a conditional, and the superclass of `K = Class.new(Base)`. `target`
        # is the class the module joins, `ancestor` the module (or superclass); each is a {Reference} resolved in
        # the call's nesting, or nil when it is not a constant the walk can name — a local receiver, an
        # `include` whose `self` is unknown, or a computed argument (`K.include(mods.first)`). {Graph} reads
        # these only to widen a `const_get` on `self`'s reach, never for ordinary constant resolution.
        Ancestry = Data.define(:target, :ancestor, :path, :line)

        Result = Data.define(:declarations, :references, :dynamic_uses, :ancestries) do
          def initialize(ancestries: [].freeze, **) = super
        end

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
        # `role`, when given, is the referring file's role, decided by the caller instead of from `path` (#1760).
        def self.call(path:, source:, target_ruby: nil, root: nil, role: nil)
          parsed = if target_ruby
                     Prism.parse(source, filepath: path,
                                         version: target_ruby)
                   else
                     Prism.parse(source, filepath: path)
                   end
          return nil unless parsed.success?

          walker = Walker.new(path: path, role: role || role_for(path, root: root))
          walker.walk(parsed.value, [])
          Result.new(declarations: walker.declarations.freeze, references: walker.references.freeze,
                     dynamic_uses: walker.dynamic_uses.freeze, ancestries: walker.ancestries.freeze)
        end

        # The values a local variable can hold, read off its assignments in one local scope, for a
        # dynamic-resolution argument built a line before the call (#1734).
        module LocalValues
          module_function

          # The assigned value nodes of `name` in `scope`, or nil when there is none or one of the assignments
          # cannot be read off its node (`+=`, a multiple assignment, `rescue => name`).
          def values(scope, name)
            writes = []
            collect_local_writes(scope, name, writes)
            return nil if writes.empty? || writes.any? { |write| !VALUE_WRITES.include?(write.class) }

            writes.map(&:value)
          end

          # The names a block's parameter list binds, block-locals included.
          def bindings(parameters)
            out = []
            collect_block_bindings(parameters, out)
            out
          end

          VALUE_WRITES = [Prism::LocalVariableWriteNode, Prism::LocalVariableOrWriteNode,
                          Prism::LocalVariableAndWriteNode].freeze
          private_constant :VALUE_WRITES

          LOCAL_WRITES = (VALUE_WRITES + [Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableTargetNode]).freeze
          private_constant :LOCAL_WRITES

          # Nodes that open a new local-variable scope. A block does not: it shares its method's locals.
          SCOPE_GATES = [Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode].freeze
          private_constant :SCOPE_GATES

          def collect_local_writes(node, name, out)
            node.rigor_each_child do |child|
              next if SCOPE_GATES.any? { |gate| child.is_a?(gate) }

              out << child if LOCAL_WRITES.any? { |kind| child.is_a?(kind) } && child.name == name
              collect_local_writes(child, name, out)
            end
          end

          BLOCK_BINDINGS = [Prism::RequiredParameterNode, Prism::OptionalParameterNode, Prism::RestParameterNode,
                            Prism::RequiredKeywordParameterNode, Prism::OptionalKeywordParameterNode,
                            Prism::KeywordRestParameterNode, Prism::BlockParameterNode,
                            Prism::BlockLocalVariableNode].freeze
          private_constant :BLOCK_BINDINGS

          def collect_block_bindings(node, out)
            out << node.name if BLOCK_BINDINGS.any? { |kind| node.is_a?(kind) } && node.name
            node.rigor_each_child { |child| collect_block_bindings(child, out) }
          end
        end

        # `Const = Class.new` / `Module.new` / `Data.define(...)` / `Struct.new(...)` declare a class under a
        # constant, and `ScopeIndexer#record_class_new_constant_decl` already treats them as class declarations
        # for cross-file resolution. The report must agree, or every such constant reads as an unreferenced
        # value rather than a class.
        META_NEW = { "Class" => :new, "Module" => :new, "Data" => :define, "Struct" => :new }.freeze
        private_constant :META_NEW

        # ADR-102 WD4 — the {Walker}'s reading of dynamic constant resolution: `constantize` and `const_get`
        # sites, the receivers a `const_get` looks its name up from, and the values its argument can hold.
        module DynamicSites
          private

          # Names that turn a String into a constant. `constantize` / `safe_constantize` are ActiveSupport;
          # `const_get` is core and may carry an explicit receiver (`Object.const_get`, `self.class.const_get`).
          DYNAMIC_RESOLVERS = %i[constantize safe_constantize const_get].freeze
          private_constant :DYNAMIC_RESOLVERS

          # The anchor of a lookup that starts at the top level.
          TOP_LEVEL = ""
          private_constant :TOP_LEVEL

          SUBJECT_SHAPES = {
            Prism::StringNode => "a literal string",
            Prism::SymbolNode => "a literal symbol",
            Prism::InterpolatedStringNode => "an interpolated string",
            Prism::InterpolatedSymbolNode => "an interpolated symbol"
          }.freeze
          private_constant :SUBJECT_SHAPES

          # Calls that hand a string or symbol through unchanged, as far as the name it spells: `"V#{v}".freeze`.
          PASS_THROUGH = %i[freeze to_s to_str to_sym dup -@ +@].freeze
          private_constant :PASS_THROUGH

          # Blocks whose `self` is not the enclosing declaration: a concern's `included` / `class_methods` body
          # runs on the including class, and an eval block on its receiver.
          SELF_REBINDING = %i[included prepended extended class_methods class_eval module_eval class_exec
                              module_exec instance_eval instance_exec].freeze
          private_constant :SELF_REBINDING

          # The `*_eval` / `*_exec` family: on a constant receiver, the block's `self` IS that constant (#1878).
          EVAL_FAMILY = %i[class_eval module_eval class_exec module_exec instance_eval instance_exec].freeze
          private_constant :EVAL_FAMILY

          # Calls that define a method from their block: `define_method`'s block is an instance method's body,
          # `define_singleton_method`'s a singleton method's (#1946).
          METHOD_DEFINERS = { define_method: :instance, define_singleton_method: :singleton }.freeze
          private_constant :METHOD_DEFINERS

          # A call is a dynamic-resolution site, and its block may run with another `self` ({#rebinds_self?}).
          def record_call(node, nesting)
            record_dynamic_use(node, nesting)
            record_mixin(node, nesting)
            return unless node.block.is_a?(Prism::BlockNode)

            classify_block(node, nesting)
          end

          def classify_block(node, nesting)
            block = node.block
            if rebinds_self?(node)
              @rebinding_blocks << block
              frame = eval_frame(node, nesting)
              @eval_frames[block] = frame if frame
            elsif meta_new_call?(node)
              @meta_new_blocks << block
            elsif METHOD_DEFINERS.key?(node.name) && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
              @definer_blocks[block] = METHOD_DEFINERS.fetch(node.name)
            end
          end

          # The `self` of an eval call's block (#1878, #1946): the receiver when it is a constant, `:unknown` when
          # it is a local or another computed value, and nil — the reading the walk had before — on `self`,
          # `self.class`, an implicit receiver or `Object`. `singleton_defs` is whether a plain `def` in the block
          # defines a singleton method of the receiver (`instance_eval`) rather than an instance method.
          def eval_frame(call, nesting)
            return anonymous_subclass_frame(call, nesting) if call.name == :new
            return nil unless EVAL_FAMILY.include?(call.name)

            singleton_defs = %i[instance_eval instance_exec].include?(call.name)
            receiver = call.receiver
            return EvalFrame.new(receiver_reference(receiver, nesting), singleton_defs) if constant_receiver?(receiver)
            return nil if receiver.nil? || self_receiver?(receiver) || constant_path?(receiver)

            EvalFrame.new(:unknown, singleton_defs)
          end

          # Rigor knows the argument's shape, which is the whole reason this can be tiered rather than treated
          # as a blanket namespace poison: a literal argument names the exact constant and is as good as a
          # written reference, while an interpolated one can only bound the names its literal head reaches.
          #
          # A local variable argument is read through its assignments in the same local scope, because the
          # name is usually built one line up: GitLab's `Migration[2.2]` is `name = "V#{...}"` followed by
          # `const_get(name, false)` (#1734).
          def record_dynamic_use(node, nesting)
            return unless DYNAMIC_RESOLVERS.include?(node.name)

            subject = node.name == :const_get ? node.arguments&.arguments&.first : node.receiver
            return if subject.nil?

            anchors = node.name == :const_get ? const_get_anchors(node, nesting) : [TOP_LEVEL]
            subjects(subject).each { |value| record_dynamic_subject(node, value, anchors) }
          end

          def record_dynamic_subject(node, subject, anchors)
            name, head = dynamic_target(subject)
            # A literal whose bytes are not valid UTF-8 cannot name a constant; dropping it is the only safe
            # answer, and carrying it forward crashed the whole run downstream.
            return if subject.is_a?(Prism::StringNode) && name.nil?
            return if subject.is_a?(Prism::SymbolNode) && name.nil?

            reason = "#{node.name} on #{SUBJECT_SHAPES.fetch(subject.class, 'a computed value')}"
            bounds = if name then literal_bounds(node, name, anchors)
                     elsif head then anchors.filter_map { |anchor| bound(head, anchor) }.uniq
                     else []
                     end
            bounds = [[nil, :namespace, nil]] if bounds.empty?
            record_anywhere(node, name, reason)
            bounds.each do |prefix, scope, within|
              @dynamic_uses << DynamicUse.new(name: name, prefix: prefix, scope: scope, within: within,
                                              inherit: anchors.include?(TOP_LEVEL), role: @role,
                                              receiver_open: !within.nil? && runtime_self?(node),
                                              site: site(node), path: @path, line: node.location.start_line,
                                              reason: reason)
            end
          end

          # A literal name is looked up from each receiver the call can have, so it carries the receiver as
          # `within` and {Graph} resolves it there first (#1761). A rooted name, or a call whose only anchor is
          # the top level, is looked up from the top level as any reference is.
          #
          # On `self` the receiver is the enclosing declaration only where the walk can name it ({#self_lookup}).
          # Where `self` is a `Class` or a singleton class, Ruby looks the name up at the top level. Where the
          # walk cannot tell what `self` is, the name is read BOTH at the enclosing declaration and at the top
          # level: either reading alone lists a live constant as a candidate when it is the wrong one, and a
          # dead constant kept reachable is the cheaper mistake. An interpolated name keeps every anchor, since
          # a taint is safe to over-reach.
          def literal_bounds(node, name, anchors)
            return [] if name.start_with?("::")

            within = anchors.grep(Reference).map { |receiver| [nil, :namespace, receiver] }
            return within unless self_receiver?(node.receiver)

            case self_lookup(node.receiver)
            when :declaration then within
            when :top_level then []
            else within + [[nil, :namespace, nil]]
            end
          end

          # A literal `const_get` on a `self` the walk cannot name at all reaches any declaration of that name.
          def record_anywhere(node, name, reason)
            return unless name && !name.start_with?("::") && unknown_self?(node)

            @dynamic_uses << DynamicUse.new(name: name, prefix: nil, anywhere: true, role: @role, site: site(node),
                                            path: @path, line: node.location.start_line, reason: reason)
          end

          # Whether a `const_get` on `self` can run on a descendant of the enclosing declaration (#1878): in a
          # method, or a block that rebinds `self`, `self` is whichever subclass or includer the method was
          # called on. Directly in a class body, or inside `Other.class_eval { }`, it is the declaration itself.
          def runtime_self?(node)
            node.name == :const_get && self_receiver?(node.receiver) && @eval_frame.nil? &&
              !(@self_kind == :declaration && !@in_block && !@self_rebound)
          end

          # Whether a `const_get` on `self` runs on a receiver the walk cannot name at all (#1946): directly in the
          # block of an eval call on a computed receiver, or in a method that block defines when the receiver form
          # names the eval receiver ({#method_receiver?}).
          def unknown_self?(node)
            return false unless node.name == :const_get && self_receiver?(node.receiver)
            return @eval_frame.receiver == :unknown && !node.receiver.is_a?(Prism::CallNode) if @eval_frame

            !@eval_method.nil? && @eval_method.receiver == :unknown && method_receiver?(node.receiver)
          end

          # Whether `receiver` names the eval receiver in a method an eval block defines: `self.class` in an
          # instance method (`self` is an instance of the receiver or of a descendant), an implicit receiver or
          # `self` in a singleton method. An implicit `const_get` in an instance method raises `NoMethodError`.
          def method_receiver?(receiver)
            class_of_self = receiver.is_a?(Prism::CallNode)
            @eval_method.kind == :instance ? class_of_self : !class_of_self
          end

          # Inside a method an eval block on a constant defines, the receiver form that names that constant reads
          # it as a runtime `self` that may be any of its descendants (#1946).
          def eval_method_references(receiver)
            return [] unless @eval_method&.receiver.is_a?(Reference) && method_receiver?(receiver)

            [@eval_method.receiver]
          end

          # Where a `const_get` on `self` (implicit, `self`, or `self.class`) looks its name up: `:declaration`
          # when `self` is the enclosing class or module, `:top_level` when it is `Class` or a singleton class,
          # `:unknown` otherwise. A block's `self` is unknown — `included do`, `class_eval` and an instance-
          # evaluated DSL block (`configure { }`, an RSpec `describe` body) all rebind it, and the walk cannot
          # tell those from an `each` block. So is the `self` of a `def Other.x` or of a `class << Other` body.
          def self_lookup(receiver)
            return :declaration if @eval_frame&.receiver.is_a?(Reference) && !receiver.is_a?(Prism::CallNode)
            return :unknown if @in_block || @self_rebound

            class_of_self = receiver.is_a?(Prism::CallNode)
            case @self_kind
            when :declaration, :singleton_method then class_of_self ? :top_level : :declaration
            when :instance_method then class_of_self ? :declaration : :unknown
            when :singleton_class then :top_level
            else :unknown
            end
          end

          # Where a `const_get` looks a name up, as the namespaces its interpolated argument is bounded by. The
          # receiver's namespace comes first: an implicit receiver, `self` or `self.class` is the enclosing
          # declaration, and a constant receiver is resolved by {Graph} as any reference is (`within`). With
          # the default `inherit = true` the lookup also falls through to the top level, which is all the
          # reading had before, so that stays tainted too; an explicit `false` confines it to the receiver. An
          # unknown receiver bounds nothing beyond the top level.
          def const_get_anchors(node, nesting)
            receiver = node.receiver
            namespaces =
              if self_receiver?(receiver)
                eval_self_references(receiver) || (self_references(node, nesting) + eval_method_references(receiver))
              elsif constant_receiver?(receiver)
                [receiver_reference(receiver, nesting)]
              else
                []
              end
            return [TOP_LEVEL] if namespaces.empty?

            inherit = node.arguments.arguments[1]
            inherit.is_a?(Prism::FalseNode) ? namespaces : namespaces + [TOP_LEVEL]
          end

          # Inside `Other.class_eval { }` an implicit or `self` receiver is `Other` (#1878).
          def eval_self_references(receiver)
            frame = @eval_frame
            [frame.receiver] if frame&.receiver.is_a?(Reference) && !receiver.is_a?(Prism::CallNode)
          end

          # The enclosing declaration as a rooted {Reference}, so {Graph} anchors it as it anchors a constant
          # receiver and can search its ancestors. Inside a meta-new rvalue `self` is the declared class in its
          # block but the outer scope in its arguments; the walk does not tell the two apart, so both are taken.
          def self_references(node, nesting)
            ([@owner, nesting.join("::")].compact.uniq - [TOP_LEVEL]).map do |fqn|
              Reference.new(as_written: fqn, nesting: [].freeze, from: nil, role: @role, path: @path,
                            line: node.location.start_line, rooted: true)
            end
          end

          # Whether `call`'s block runs with a `self` other than the enclosing declaration's. A meta-new block
          # assigned to a constant is that constant ({#walk_constant_write} credits it as `@owner`); an
          # anonymous one is not the enclosing declaration either.
          def rebinds_self?(call)
            return true if SELF_REBINDING.include?(call.name)

            @owner.nil? && meta_new_call?(call)
          end

          def meta_new_call?(call)
            recv = call.receiver
            name = recv && Source::ConstantPath.qualified_name_or_nil(recv)&.delete_prefix("::")
            !name.nil? && META_NEW[name] == call.name
          end

          def self_receiver?(receiver)
            receiver.nil? || receiver.is_a?(Prism::SelfNode) ||
              (receiver.is_a?(Prism::CallNode) && receiver.name == :class && receiver.receiver.is_a?(Prism::SelfNode))
          end

          # `Object.const_get` is the top level, which every lookup already reaches.
          def constant_receiver?(receiver)
            return false unless receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)

            as_written = Source::ConstantPath.qualified_name_or_nil(receiver)
            !as_written.nil? && as_written.delete_prefix("::") != "Object"
          end

          def receiver_reference(receiver, nesting)
            Reference.new(as_written: Source::ConstantPath.qualified_name_or_nil(receiver),
                          nesting: nesting.dup.freeze, from: nil, role: @role, path: @path,
                          line: receiver.location.start_line, rooted: Source::ConstantPath.rooted?(receiver))
          end

          # `[prefix, scope, within]` for a literal head under one anchor. A head ending in `::` names a
          # namespace and reaches everything beneath it; any other head is the start of a name, so
          # `"V#{version}"` reaches `V1_0` and `V2_2` alike, and only a string-prefix match says that. A rooted
          # head ignores the receiver. `within` carries a constant receiver for {Graph} to resolve.
          def bound(head, anchor)
            anchor = TOP_LEVEL if head.start_with?("::")
            head = head.delete_prefix("::")
            scope = head.end_with?("::") ? :namespace : :leading
            head = head.delete_suffix("::")
            return nil if head.empty?

            anchor == TOP_LEVEL ? [head, scope, nil] : [head, scope, anchor]
          end

          # The values a dynamic-resolution subject can hold: the subject itself, or for a local variable every
          # value assigned to it in the enclosing local scope. A local with an assignment whose value cannot be
          # read off the node (`+=`, a multiple assignment, `rescue => name`) stays a computed value.
          #
          # A name an enclosing block binds as a parameter or block-local (`|name|`, `|x; name|`) is that
          # block's value, not the method's: reading it through the method's assignments named a literal the
          # block never sees, and a constant only that literal named was hidden from the report.
          def subjects(subject)
            subject = pass_through(subject)
            return [subject] unless subject.is_a?(Prism::LocalVariableReadNode) && @local_scope
            return [subject] if @block_params.include?(subject.name)

            (LocalValues.values(@local_scope, subject.name) || [subject]).map { |value| pass_through(value) }
          end

          # The string or symbol under `"V#{v}".freeze` / `.to_sym`; any other node unchanged.
          def pass_through(node)
            while node.is_a?(Prism::CallNode) && PASS_THROUGH.include?(node.name) && node.arguments.nil? &&
                  node.block.nil? && SUBJECT_SHAPES.key?(pass_through(node.receiver).class)
              node = node.receiver
            end
            node
          end

          # `[exact name, literal head]` for a dynamic-resolution subject. A literal names its constant exactly;
          # an interpolation can only bound the names its literal head starts; anything else bounds nothing.
          def dynamic_target(subject)
            case subject
            when Prism::StringNode, Prism::SymbolNode then [Scan.usable_name(subject.unescaped), nil]
            when Prism::InterpolatedStringNode, Prism::InterpolatedSymbolNode then [nil, literal_head(subject)]
            else [nil, nil]
            end
          end

          # The literal head of an interpolated name, as written: `"Foo::Bar::#{k}"` gives `Foo::Bar::`. Returns
          # nil when the interpolation starts the string, which bounds nothing.
          def literal_head(node)
            head = node.parts.first
            return nil unless head.is_a?(Prism::StringNode)

            literal = Scan.usable_name(head.unescaped)
            literal.nil? || literal.empty? ? nil : literal
          end
        end

        # #1946 — the {Walker}'s reading of ancestry written outside a declaration's own statements, as
        # {Ancestry} edges: receiver-form and `send`-spelled mixin calls, a mixin call whose `self` is not the
        # enclosing declaration body, and the superclass of `K = Class.new(Base)`.
        module AncestrySites
          private

          # An anonymous `Class.new(Base) { }` block's `self` is a subclass of `Base` that declares no constant of
          # its own, so a `const_get` on it is read at `Base` (#1946).
          def anonymous_subclass_frame(call, nesting)
            superclass = call.arguments&.arguments&.first
            return nil unless call.receiver.is_a?(Prism::ConstantReadNode) && call.receiver.name == :Class &&
                              constant_receiver?(superclass)

            EvalFrame.new(receiver_reference(superclass, nesting), false)
          end

          def constant_path?(node)
            node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)
          end

          # Mixin calls: the ones a class body writes, and their `send` spellings.
          MIXINS = %i[include prepend extend].freeze
          private_constant :MIXINS

          SENDS = %i[send public_send __send__].freeze
          private_constant :SENDS

          # Records an {Ancestry} for a mixin call the declaration's own statements do not carry (#1946). A
          # receiver-less `include` directly in a class body is already one of its `includes`.
          def record_mixin(node, nesting)
            modules = mixin_arguments(node)
            return if modules.nil? || modules.empty?
            return if node.receiver.nil? && !SENDS.include?(node.name) && @body_statements.include?(node)

            target = mixin_target(node, nesting)
            modules.each do |arg|
              ancestor = arg.is_a?(Prism::SelfNode) ? target : mixin_reference(arg, nesting)
              next if target.nil? && ancestor.nil?

              @ancestries << Ancestry.new(target: target, ancestor: ancestor, path: @path,
                                          line: node.location.start_line)
            end
          end

          # The module arguments of a mixin call, or nil when it is not one.
          def mixin_arguments(node)
            args = node.arguments&.arguments || []
            return args if MIXINS.include?(node.name)
            return nil unless SENDS.include?(node.name)

            verb = args.first
            name = verb.unescaped if verb.is_a?(Prism::SymbolNode) || verb.is_a?(Prism::StringNode)
            MIXINS.include?(name&.to_sym) ? args.drop(1) : nil
          end

          def mixin_reference(arg, nesting)
            return nil unless constant_path?(arg) && Source::ConstantPath.qualified_name_or_nil(arg)

            receiver_reference(arg, nesting)
          end

          # The class a mixin call adds to: a constant receiver, or for `self` and an implicit receiver whatever
          # `self` is — the eval receiver in an eval block, the enclosing declaration in its body. Anything else,
          # the top level (`Object`, whose descendants are every class) included, is unknown (nil).
          def mixin_target(node, nesting)
            receiver = node.receiver
            return mixin_reference(receiver, nesting) unless receiver.nil? || receiver.is_a?(Prism::SelfNode)

            self_target(node, nesting)
          end

          # What `self` is at `node` as a {Reference}, where the walk can name it; nil otherwise.
          def self_target(node, nesting)
            frame = @eval_frame
            return frame&.receiver.is_a?(Reference) ? frame.receiver : nil if frame || @eval_method
            return nil if @in_block || @self_rebound || @self_kind != :declaration || nesting.empty?

            rooted_reference(nesting.join("::"), node)
          end

          def rooted_reference(fqn, node)
            Reference.new(as_written: fqn, nesting: [].freeze, from: nil, role: @role, path: @path,
                          line: node.location.start_line, rooted: true)
          end

          # `K = Class.new(Base)` makes `Base` an ancestor of `K` (#1946). It stays out of the declaration's
          # `superclass`, which ordinary constant resolution reads: the engine does not resolve a constant
          # through a `Class.new` superclass either, and the two are pinned to agree.
          def record_class_new_superclass(call, fqn, nesting)
            superclass = call.arguments&.arguments&.first
            return unless call.receiver.name == :Class && superclass

            ancestor = if superclass.is_a?(Prism::SelfNode) then self_target(call, nesting)
                       else mixin_reference(superclass, nesting)
                       end
            @ancestries << Ancestry.new(target: rooted_reference(fqn, call), ancestor: ancestor,
                                        path: @path, line: call.location.start_line)
          end

          # The receiver-less statements directly in a declaration body.
          def body_statements(body)
            body.child_nodes.select { |stmt| stmt.is_a?(Prism::CallNode) && stmt.receiver.nil? }
                .to_set.compare_by_identity
          end
        end

        # The `self` of an eval block ({DynamicSites#eval_frame}): a {Reference}, or `:unknown`.
        EvalFrame = Data.define(:receiver, :singleton_defs)
        # A method an eval block defines on its receiver, and whether it is an `:instance` or `:singleton` method.
        EvalMethod = Data.define(:receiver, :kind)

        # Single-pass walker. Tracks `nesting` as the stack of enclosing declaration names.
        class Walker
          include DynamicSites
          include AncestrySites

          attr_reader :declarations, :references, :dynamic_uses, :ancestries

          def initialize(path:, role:)
            @path = path
            @role = role
            @declarations = []
            @references = []
            @dynamic_uses = []
            @ancestries = []
            # The receiver-less statements directly in the declaration body being walked, which its own
            # `includes` already carry. See {#record_mixin}.
            @body_statements = Set.new.compare_by_identity
            # The declaration a meta-new rvalue is being walked for, or nil. See {#walk_constant_write}.
            @owner = nil
            # The node whose subtree holds the local variables in scope: the file, a method, or a class body.
            @local_scope = nil
            # Names an enclosing block's parameters or block-locals shadow within @local_scope.
            @block_params = Set.new.freeze
            # Whether `self` here is something other than the enclosing declaration — inside an `included do`,
            # `class_eval` or anonymous `Class.new` block. See {#rebinds_self?}.
            @self_rebound = false
            @rebinding_blocks = Set.new.compare_by_identity
            # The {EvalFrame} of each `*_eval` block, and the one whose `self` the walk is directly in (nil when
            # `self` is not an eval receiver). See {#eval_frame}.
            @eval_frames = {}.compare_by_identity
            @eval_frame = nil
            # Inside a method an eval block defines (a `def`, or a `define_method` / `define_singleton_method`
            # block), the eval receiver and the method's kind; nil elsewhere. See {#eval_method_references}.
            @eval_method = nil
            @meta_new_blocks = Set.new.compare_by_identity
            @definer_blocks = {}.compare_by_identity
            # What `self` is here, for {#self_lookup}: `:declaration` in a class or module body (and at the top
            # level), `:singleton_method` in a `def self.x` or a def in a `class << self` body,
            # `:instance_method` in any other def, `:singleton_class` in a `class << self` body outside its
            # methods, and `:unknown` where the walk cannot name it.
            @self_kind = :declaration
            # Whether the walk is inside a block, whose `self` it cannot name. See {#self_lookup}.
            @in_block = false
            # Whether the innermost declaration is a module, whose instance methods' `self.class` is not it.
            @module_body = false
          end

          def walk(node, nesting)
            return unless node.is_a?(Prism::Node)

            case node
            when Prism::ClassNode  then return walk_declaration(node, nesting, superclass: node.superclass)
            when Prism::ModuleNode then return walk_declaration(node, nesting, superclass: nil, module_body: true)
            when Prism::ConstantReadNode, Prism::ConstantPathNode
              record_reference(node, nesting)
              # A constant path's segments are not separate references — `A::B::C` is one reference to the leaf,
              # and descending would record `A` and `A::B` as references in their own right (22 spurious
              # candidates on Rigor's own lib came from exactly that in the #345 probe).
              #
              # A path on a computed base is the exception: `Migration[2.2]::MigrationRecord` names no constant
              # this reading can resolve, but its base is a call whose receiver and arguments do.
              walk(node.parent, nesting) if node.is_a?(Prism::ConstantPathNode) &&
                                            Source::ConstantPath.qualified_name_or_nil(node).nil?
              return
            when Prism::ConstantWriteNode
              walk_constant_write(node, nesting)
              return
            when Prism::CallNode
              record_call(node, nesting)
            when Prism::ProgramNode, Prism::DefNode, Prism::SingletonClassNode
              return in_local_scope(node) { node.rigor_each_child { |child| walk(child, nesting) } }
            when Prism::BlockNode, Prism::LambdaNode
              return in_block(node) { node.rigor_each_child { |child| walk(child, nesting) } }
            end

            node.rigor_each_child { |child| walk(child, nesting) }
          end

          private

          def walk_declaration(node, nesting, superclass:, module_body: false)
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
            walk_body(node.body, nesting + [name], module_body)
          end

          def walk_body(body, nesting, module_body)
            saved = [@owner, @self_rebound, @in_block, @module_body, @body_statements]
            @owner = nil
            @self_rebound = @in_block = false
            @module_body = module_body
            @body_statements = body_statements(body)
            in_local_scope(body, :declaration) { walk(body, nesting) }
          ensure
            @owner, @self_rebound, @in_block, @module_body, @body_statements = saved
          end

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
            record_class_new_superclass(call, fqn, nesting)
            fqn
          end

          # `include` / `prepend` / `extend` argument names written directly in the declaration body. Only the
          # top level of the body is inspected: a mixin applied inside a conditional or a nested def is not a
          # static ancestor edge.
          def mixin_names(body)
            body.child_nodes.flat_map do |stmt|
              next [] unless stmt.is_a?(Prism::CallNode) && %i[include prepend extend].include?(stmt.name)
              next [] if stmt.receiver

              (stmt.arguments&.arguments || []).filter_map { |arg| Source::ConstantPath.qualified_name_or_nil(arg) }
            end
          end

          def in_local_scope(scope, self_kind = self_kind_in(scope))
            saved = [@local_scope, @block_params, @self_kind, @eval_frame, @eval_method]
            @eval_method = eval_def(scope)
            @eval_frame = nil
            @local_scope = scope
            @block_params = Set.new.freeze
            @self_kind = self_kind
            yield
          ensure
            @local_scope, @block_params, @self_kind, @eval_frame, @eval_method = saved
          end

          # The method a `def` directly in an eval block defines on the eval receiver (#1946): a plain `def` is an
          # instance method, or a singleton one under `instance_eval`; a `def self.x` is a singleton method.
          def eval_def(scope)
            frame = @eval_frame
            return nil unless frame && scope.is_a?(Prism::DefNode)

            if scope.receiver.nil? then EvalMethod.new(frame.receiver, frame.singleton_defs ? :singleton : :instance)
            elsif scope.receiver.is_a?(Prism::SelfNode) then EvalMethod.new(frame.receiver, :singleton)
            end
          end

          # The {#self_lookup} kind inside `scope`, from the kind around it. Only a receiver-less def or a `def
          # self.x` directly in a declaration body, and a `class << self` there, keep `self` nameable.
          def self_kind_in(scope)
            case scope
            when Prism::ProgramNode then :declaration
            when Prism::SingletonClassNode
              scope.expression.is_a?(Prism::SelfNode) && @self_kind == :declaration ? :singleton_class : :unknown
            when Prism::DefNode then def_self_kind(scope)
            else :unknown
            end
          end

          # A receiver-less def names its `self` only directly in a class body or a `class << self` body. In a
          # module body `self.class` is the includer's class, or `Module` under `module_function` / `extend
          # self`; a def nested in another def lands on whatever that method's cref is, which the walk cannot
          # tell apart.
          def def_self_kind(node)
            if node.receiver.nil?
              case @self_kind
              when :singleton_class then :singleton_method
              when :declaration then @module_body ? :unknown : :instance_method
              else :unknown
              end
            elsif node.receiver.is_a?(Prism::SelfNode) && @self_kind == :declaration
              :singleton_method
            else
              :unknown
            end
          end

          def in_block(block)
            saved = [@block_params, @self_rebound, @in_block, @eval_frame, @eval_method]
            names = block.parameters ? LocalValues.bindings(block.parameters) : []
            @block_params = (@block_params | names).freeze unless names.empty?
            enter_block_self(block)
            @in_block = true
            yield
          ensure
            @block_params, @self_rebound, @in_block, @eval_frame, @eval_method = saved
          end

          # A block whose `self` is another object drops the eval reading around it: an eval block sets its own
          # (#1878), and a `Class.new` / `Struct.new` block's `self` is the class it builds. A `define_method` /
          # `define_singleton_method` block directly in an eval block is a method of the eval receiver (#1946).
          def enter_block_self(block)
            if @rebinding_blocks.include?(block)
              @self_rebound = true
              @eval_frame = @eval_frames[block]
              @eval_method = nil
            elsif @meta_new_blocks.include?(block)
              @eval_frame = @eval_method = nil
            elsif @eval_frame && @definer_blocks.key?(block)
              @eval_method = EvalMethod.new(@eval_frame.receiver, @definer_blocks.fetch(block))
              @eval_frame = nil
            end
          end

          def site(node)
            "#{@path}:#{node.location.start_line}"
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
