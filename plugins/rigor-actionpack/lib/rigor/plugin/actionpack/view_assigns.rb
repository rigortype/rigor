# frozen_string_literal: true

require "prism"

require_relative "controller_scan"

module Rigor
  module Plugin
    class Actionpack < Rigor::Plugin::Base
      # #393 — which controller action renders which template, and what it assigned.
      #
      # A template unit's `ivar_seeds:` are the controller's assigns, and the design note (§ 11.3) names
      # `ScopeIndexer`'s per-method definite-assignment table as the source. That table does not exist yet
      # when a unit is built: `#template_units_for_file` runs on the parent BEFORE any analysis, which is
      # what keeps the plugin off every hot path. So the seeds are derived here, syntactically, from the
      # controller sources the plugin already reads for its filter-chain index.
      #
      # ## The inference is deliberately narrow
      #
      # Only `@user = Model.find(...)`-shaped assignments contribute, and only for a closed set of
      # constructors and finders that **cannot return nil** — `find`, `find_by!`, `sole`, `first!`,
      # `last!`, `new`, `create`, `create!`. A seeded type is a claim the engine acts on, and a wrong one
      # is worse than none: seeding `@user` from `find_by` (which returns nil at runtime) would hand the
      # flow rules a non-nil nominal and license folds that draw diagnostics on correct templates — the
      # trap `Actionpack::STRONG_PARAMS_CHAIN_METHODS` documents at length for `Parameters#[]`. Anything
      # else assigns nothing, the ivar stays unseeded, and the template reads it as `Dynamic`, which
      # taints honestly (ADR-5). A call on that list that returns, or may return, SEVERAL records —
      # `find(a, b)`, `find([1, 2])`, `create([{…}, {…}])` — is excluded by the same rule; see
      # {Builder#single_record?}.
      #
      # Two assignments of the same ivar that disagree drop it for that template, for the same reason.
      #
      # ## Which templates an action reaches
      #
      # The implicit render (`UsersController#show` → `users/show`) plus the explicit forms
      # {Analyzer.render_target_for} already recognises at a render site: `render :edit`,
      # `render "admin/shared/form"`. A partial reached through `render partial:` inherits nothing: its
      # assigns come from whichever template renders it, which this slice does not trace (see the
      # follow-up named in `docs/internal-spec/macro-substrate.md`).
      class ViewAssigns
        # Finders and constructors whose Rails implementation raises rather than returning nil. Anything
        # nil-able is excluded on purpose; see the class comment.
        NON_NIL_PRODUCERS = %i[find find_by! find_sole_by sole first! last! new create create!].freeze

        # `{ "users/show" => { "@user" => "User" } }`, logical template name (no format, no handler) to
        # seeds. A template's unit looks itself up by the same name with the format stripped.
        attr_reader :by_template

        def initialize(by_template)
          @by_template = by_template.freeze
          freeze
        end

        def self.empty
          new({})
        end

        # `users/show.html` → the seeds recorded for `users/show`. The format is dropped because a
        # controller action renders one logical template across every format it responds to, and the
        # assigns are the same for all of them.
        #
        # A PARTIAL (`users/_card.html`) has no action of its own, but an ivar is not a local: Rails puts
        # the controller's assigns on the view context, so `@user` reads the same inside a partial as in
        # the template that rendered it. Its seeds are therefore the union of the seeds of the templates
        # in its own directory — the directory is the controller, by Rails' own convention — with any ivar
        # the members type differently dropped, the same conflict rule that applies within one action.
        #
        # That is an approximation in one direction only: a partial rendered from ANOTHER controller's
        # view sees that controller's assigns, which are not in this union, so the ivar stays unseeded and
        # reads `Dynamic`. Tracing render sites across templates is the follow-up
        # `docs/internal-spec/macro-substrate.md` names.
        def seeds_for(logical_name)
          name = logical_name.sub(%r{\.[^./]+\z}, "")
          return @by_template.fetch(name, {}) unless partial?(name)

          directory_seeds(name)
        end

        def partial?(name)
          File.basename(name).start_with?("_")
        end

        def directory_seeds(name)
          prefix = name.include?("/") ? "#{File.dirname(name)}/" : ""
          seeds = {}
          conflicts = []
          @by_template.each do |template, assigns|
            next unless template.start_with?(prefix) && !template.delete_prefix(prefix).include?("/")

            assigns.each do |ivar, type_name|
              conflicts << ivar if seeds.key?(ivar) && seeds[ivar] != type_name
              seeds[ivar] = type_name
            end
          end
          conflicts.each { |ivar| seeds.delete(ivar) }
          seeds
        end

        # Builds the index from the controller sources under `search_paths`.
        class Builder
          def initialize(io_boundary:, search_paths:)
            @io_boundary = io_boundary
            @search_paths = search_paths
          end

          def build
            by_template = {}
            controller_files.each { |path| harvest(path, by_template) }
            ViewAssigns.new(by_template.transform_values(&:freeze))
          end

          private

          def controller_files
            @search_paths.flat_map do |root|
              absolute = File.expand_path(root)
              next [] unless @io_boundary.directory?(absolute)

              Dir.glob(File.join(absolute, "**", "*.rb"))
            end
          end

          def harvest(path, by_template)
            contents = @io_boundary.read_file(path)
            result = Prism.parse(contents)
            return unless result.errors.empty?

            ControllerScan.each_controller(result.value, []) do |node, namespace|
              harvest_controller(node, namespace, by_template)
            end
          rescue Plugin::AccessDeniedError, Errno::ENOENT
            nil
          end

          def harvest_controller(node, namespace, by_template)
            segments = namespace + ControllerScan.constant_segments(node.constant_path)
            prefix = ControllerScan.controller_path(segments)
            return if prefix.nil?

            methods = ControllerScan.method_bodies(node)
            filters = filter_chain(node)
            methods.each do |name, body|
              assigns = filter_assigns(filters, name, methods).merge(ivar_assigns(body))
              next if assigns.empty?

              templates_for(name, body, prefix).each do |template|
                merge_seeds(by_template, template, assigns)
              end
            end
          end

          # `before_action :set_user, only: %i[show edit]` → `[[:set_user, [:show, :edit], nil]]`.
          # `except:` rides the third slot. `prepend_before_action` is the same chain; `after_action` and
          # `around_action` are not — an assign made after the render cannot be a seed.
          def filter_chain(node)
            body = node.body
            return [] if body.nil?

            body.child_nodes.compact.flat_map do |child|
              next [] unless child.is_a?(Prism::CallNode) && child.receiver.nil?
              next [] unless %i[before_action prepend_before_action].include?(child.name)

              filter_entries(child)
            end
          end

          def filter_entries(call)
            arguments = call.arguments&.arguments || []
            options = arguments.last.is_a?(Prism::KeywordHashNode) ? arguments.pop : nil
            names = arguments.filter_map { |argument| argument.is_a?(Prism::SymbolNode) ? argument.unescaped.to_sym : nil }
            only = symbol_list(options, :only)
            except = symbol_list(options, :except)
            conditional = %i[if unless].any? { |key| option?(options, key) }
            names.map { |name| [name, only, except, conditional] }
          end

          def option?(options, key)
            !pair_for(options, key).nil?
          end

          def symbol_list(options, key)
            pair = pair_for(options, key)
            return nil if pair.nil?

            symbols_in(pair.value)
          end

          def pair_for(options, key)
            return nil if options.nil?

            options.elements.find do |element|
              element.is_a?(Prism::AssocNode) && element.key.is_a?(Prism::SymbolNode) &&
                element.key.unescaped.to_sym == key
            end
          end

          def symbols_in(node)
            case node
            when Prism::SymbolNode then [node.unescaped.to_sym]
            when Prism::ArrayNode then node.elements.filter_map { |e| e.unescaped.to_sym if e.is_a?(Prism::SymbolNode) }
            else []
            end
          end

          # The assigns every `before_action` that UNCONDITIONALLY runs for `action` made, in chain order,
          # so a later filter's assignment of the same ivar wins — and the action's own assignment wins
          # over all of them, which is why the caller merges this UNDER the action's.
          #
          # `only:` / `except:` are decided here, per action, because they are static. `if:` / `unless:`
          # cannot be: the filter may not run, so nothing it assigns is definite, and seeding from it
          # would claim a non-nil type for an ivar that is nil at render time — see {#definite?}.
          def filter_assigns(filters, action, methods)
            filters.each_with_object({}) do |(name, only, except, conditional), seeds|
              next if conditional
              next if only && !only.include?(action)
              next if except&.include?(action)

              body = methods[name]
              next if body.nil?

              seeds.merge!(ivar_assigns(body))
            end
          end

          # `@user = User.find(params[:id])` → `{ "@user" => "User" }`.
          #
          # **Definite assignments only.** An assignment the method may not reach — inside an `if`, a
          # `case`, a `rescue`, a loop, or a block that may not run — does not contribute, because a seed
          # is a claim about what the template will FIND, and `@user = User.find(1) if params[:pick]`
          # leaves `@user` nil on the other path. A non-nil nominal standing in for a runtime nil is the
          # `Parameters#[]` trap (`Actionpack::STRONG_PARAMS_CHAIN_METHODS`): the flow rules act on it and
          # report live branches, which is exactly what a reader of a template would see with
          # `view_type_checks:` on. The unseeded ivar reads `Dynamic` instead and taints honestly (ADR-5).
          #
          # Two disagreeing types drop the ivar for the same reason.
          def ivar_assigns(body)
            seeds = {}
            conflicts = []
            walk_assignments(body) do |name, type_name|
              existing = seeds[name]
              conflicts << name if existing && existing != type_name
              seeds[name] = type_name
            end
            conflicts.each { |name| seeds.delete(name) }
            seeds
          end

          # The nodes a method body reaches on EVERY path: its own statement list, a parenthesised
          # expression, and a `begin` that cannot be cut short. Everything else — `if` / `unless` /
          # `case` / `while` / `until` / `rescue` / `for`, and any block — is a branch, so the walk stops
          # there rather than descending.
          def walk_assignments(node, &)
            return unless node.is_a?(Prism::Node)

            if node.is_a?(Prism::InstanceVariableWriteNode)
              type_name = produced_type(node.value)
              yield node.name.to_s, type_name if type_name
              return
            end
            return unless definite?(node)

            node.rigor_each_child { |child| walk_assignments(child, &) }
          end

          # A `BeginNode` carrying a `rescue_clause` is NOT every-path, and that covers `def show; … rescue
          # …; end` as well as an explicit `begin`: an exception raised by the first statement leaves the
          # rest unassigned, and if the rescue renders anything the template reads a nil ivar. An
          # `ensure`-only `begin` has no such exit and stays. The modifier form
          # (`@u = User.find(1) rescue render :missing`) never seeds either — its value node is a
          # `RescueModifierNode`, which {#produced_type} does not recognise.
          def definite?(node)
            return node.rescue_clause.nil? if node.is_a?(Prism::BeginNode)

            node.is_a?(Prism::StatementsNode) || node.is_a?(Prism::ParenthesesNode)
          end

          # The narrow inference. `Model.find(…)` / `Model.new` → `"Model"`, and nothing else.
          def produced_type(value)
            return nil unless value.is_a?(Prism::CallNode)
            return nil unless NON_NIL_PRODUCERS.include?(value.name)
            return nil unless single_record?(value)

            receiver = value.receiver
            return nil unless receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)

            name = ControllerScan.constant_segments(receiver).join("::")
            name.empty? ? nil : name
          end

          # Argument shapes that can stand for several ids, or several attribute hashes, at once.
          LIST_ARGUMENTS = [Prism::SplatNode, Prism::ArrayNode, Prism::ForwardingArgumentsNode].freeze
          private_constant :LIST_ARGUMENTS

          # Whether the call returns ONE record. A seed names a class and nothing more — `resolve` in
          # `Analysis::TemplateUnits` looks the string up as a nominal — so an `Array[Model]` result has no
          # spelling here, and seeding the element type would contradict rigor-activerecord, which types the
          # controller's own `Model.find(a, b)` as `Array[Model]` (#1321).
          #
          # `find` therefore seeds only for exactly one plain positional argument and no block. Two or more
          # ids return an Array. So may `find([1, 2])` and `find(*ids)`: rigor-activerecord keeps the model
          # for both, because a composite key's tuple is one record, but the view declines where the runtime
          # answer may be an Array, which leaves it `Dynamic` rather than contradicting the controller. A
          # block hands the call to `Enumerable#find`, which the arity rule does not describe. One argument
          # that merely EVALUATES to an Array (`find(params[:ids])`, `create(rows)`) cannot be told apart from
          # one id or one attribute hash — the limit the bundled `Relation#find` RBS states too — and keeps
          # the model, as it does there. `create` / `create!` given an Array of attribute hashes return one
          # record per hash.
          def single_record?(call)
            arguments = call.arguments&.arguments || []
            case call.name
            when :find
              arguments.size == 1 && call.block.nil? && !list_argument?(arguments.first) &&
                !arguments.first.is_a?(Prism::KeywordHashNode)
            when :create, :create!
              arguments.none? { |argument| list_argument?(argument) }
            else
              true
            end
          end

          def list_argument?(node)
            LIST_ARGUMENTS.any? { |klass| node.is_a?(klass) }
          end

          # The implicit render plus every explicit one the body spells. An action that renders nothing
          # recognisable still gets its implicit template — that is Rails' default, not a guess.
          def templates_for(action, body, prefix)
            templates = ["#{prefix}/#{action}"]
            ControllerScan.each_render(body) do |node|
              target = render_target(node, prefix)
              templates << target if target
            end
            templates.uniq
          end

          # `render :edit` and `render "admin/shared/form"` only. `render partial:` is excluded: a partial's
          # bindings are the render site's `locals:` — which {RenderLocals} reads — not the action's
          # assigns, and seeding it with the latter would state something the call site did not.
          def render_target(node, prefix)
            case (first = node.arguments&.arguments&.first)
            when Prism::SymbolNode then "#{prefix}/#{first.unescaped}"
            when Prism::StringNode then first.unescaped
            end
          end

          # A template rendered by two actions gets the UNION of their assigns, and an ivar the two type
          # differently is dropped — the same rule {#ivar_assigns} applies within one action, for the same
          # reason. Rails really does render one template from several actions (`new` and `create` on a
          # validation failure), and the seeds have to describe both.
          def merge_seeds(by_template, template, assigns)
            existing = by_template[template]
            if existing.nil?
              by_template[template] = assigns.dup
              return
            end

            assigns.each do |name, type_name|
              if existing.key?(name) && existing[name] != type_name
                existing[name] = nil
              else
                existing[name] ||= type_name
              end
            end
            existing.compact!
          end
        end
      end
    end
  end
end
