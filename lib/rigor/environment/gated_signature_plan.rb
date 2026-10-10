# frozen_string_literal: true

require "rbs"

module Rigor
  class Environment
    # Issue #1713 — loading a {RequiredFeatures}-gated vendored directory minus only what another signature
    # source already declares, instead of standing the whole directory down.
    #
    # `RbsLoader.build_env_for` first tries the directory whole. When that costs the environment something
    # (`RbsLoader.gated_failures`), it builds the environment WITHOUT the directory and plans against it with
    # {.build}: the plan is the directory's parsed declarations, rewritten in memory (the files on disk are never
    # touched), so that
    #
    # - a method, attribute or alias another source declares on the same class is left out (an overload
    #   continuation, `def m: ... | ...`, declares nothing of its own and needs the vendored base, so it keeps
    #   it);
    # - a type whose header disagrees with another source's — a class one side declares as a module, or a
    #   different generic arity — stands down as a whole: its declaration becomes a *shell*, the other source's
    #   header with no members and no superclass, which keeps the vendored types nested inside it in their
    #   lexical context;
    # - a type in `shelled` (the types the trial build of a previous plan still failed for) is shelled the same
    #   way.
    #
    # The kept declarations load where the directory would have loaded, ahead of the project's signatures, so
    # which declaration is a class's primary one does not move; the shells load after them, so a shell never
    # becomes the primary declaration of a class the project declares. The trial build stays the arbiter:
    # `build_env_for` keeps a plan's environment only when every gated type builds in it.
    #
    # {.standdowns} reads what stood down back off a built environment, the way the other `rbs.coverage.*`
    # notices are derived, so a warm run off the env cache reports what the cold run reported.
    module GatedSignaturePlan
      # Buffer name stamped on the shell declarations. Never a real path, so {.standdowns} tells a shell from the
      # vendored declaration it replaced by it.
      SHELL_BUFFER = "(rigor: vendored stand-down shells)"

      # The buffer names Rigor synthesizes declarations under. They stand for no source, so neither a plan nor
      # a stand-down report reads them as another source's declaration.
      def self.synthetic_buffers
        [SHELL_BUFFER, RbsLoader::SYNTHETIC_NAMESPACE_BUFFER, RbsLoader::SYNTHETIC_STUB_BUFFER]
      end

      # A planned load: `leading` and `shells` are `[buffer, directives, decls]` sources, `changed` is false
      # when the plan is the directory as it stands.
      Plan = Data.define(:leading, :shells, :changed)

      # One plan's walk over the vendored declarations: the environment it plans against, the types to shell
      # whatever their headers, and whether anything was left out.
      class Planner
        attr_reader :changed

        def initialize(base_env, shelled)
          @base_env = base_env
          @shelled = shelled
          @changed = false
        end

        # Splits `decls` into what loads ahead of the project's signatures and what loads after them.
        def plan_decls(decls, namespace)
          lead = []
          shell = []
          decls.each do |decl|
            unless GatedSignaturePlan.type_declaration?(decl)
              lead << decl
              next
            end

            kept, shelled = plan_type(decl, GatedSignaturePlan.qualify(namespace, decl.name))
            lead << kept if kept
            shell << shelled if shelled
          end
          [lead, shell]
        end

        private

        def plan_type(decl, name)
          others = GatedSignaturePlan.other_declarations(@base_env, name)
          nested = decl.members.select { |member| GatedSignaturePlan.type_declaration?(member) }
          nested_lead, nested_shell = plan_decls(nested, name)
          if @shelled.include?(name) || GatedSignaturePlan.header_conflict?(decl, others)
            @changed = true
            return [nil, GatedSignaturePlan.header_copy(others.first || decl, decl.name, nested_lead + nested_shell)]
          end

          wrapper = nested_shell.empty? ? nil : GatedSignaturePlan.header_copy(decl, decl.name, nested_shell)
          [keep_type(decl, others, nested_lead), wrapper]
        end

        # `decl` less the members `others` declare, with its nested types replaced by their planned kept halves.
        def keep_type(decl, others, nested_lead)
          taken = GatedSignaturePlan.declared_keys(others)
          own = decl.members.reject { |member| GatedSignaturePlan.type_declaration?(member) }
          members = own.reject { |member| GatedSignaturePlan.clashes?(member, taken) }
          @changed ||= members.size != own.size
          GatedSignaturePlan.rebuild(decl, members: members + nested_lead)
        end
      end

      module_function

      # @param roots — the gated directories (Pathnames) to plan, each loaded whole on the first attempt.
      # @param base_env — the environment built without them: every other signature source, resolved.
      # @param shelled — absolute-less type names to shell regardless of their headers.
      def build(roots, base_env, shelled = Set.new)
        planner = Planner.new(base_env, shelled)
        leading = []
        shells = []
        signature_files(roots).each do |file|
          buffer, directives, decls = RbsLoader.parse_signature_file(file)
          next if buffer.nil?

          lead, shell = planner.plan_decls(decls, nil)
          leading << [buffer, directives, lead]
          shells << [shell_buffer, directives, shell] unless shell.empty?
        end
        Plan.new(leading: leading, shells: shells, changed: planner.changed)
      end

      def signature_files(roots)
        roots.flat_map { |root| Dir.glob(File.join(root.to_s, "*.rbs")).sort }
      end

      def shell_buffer
        ::RBS::Buffer.new(name: SHELL_BUFFER, content: "")
      end

      # The declarations of `name` in `env` that some other source made, synthesized stubs left out.
      def other_declarations(env, name)
        entry = env&.class_decls&.[](::RBS::TypeName.parse("::#{name}"))
        return [] if entry.nil?

        RbsLoader.entry_declarations(entry).reject { |decl| synthetic?(decl) }
      end

      def synthetic?(decl)
        synthetic_buffers.include?(RbsLoader.declaration_buffer_name(decl))
      end

      # A class one side declares as a module, or a different number of type parameters. A disagreement the
      # declarations do not show this plainly — a superclass, a variance, a bound — is the trial build's to find.
      def header_conflict?(decl, others)
        first = others.first
        return false if first.nil?
        return true unless first.instance_of?(decl.class)

        first.type_params.size != decl.type_params.size
      end

      def declared_keys(others)
        others.each_with_object(Set.new) do |other, keys|
          other.members.each { |member| RbsLoader.member_method_keys(member).each { |key| keys << key } }
        end
      end

      def clashes?(member, taken)
        RbsLoader.member_method_keys(member).any? { |key| taken.include?(key) }
      end

      # `source`'s kind and type parameters under `name`, carrying only `members` — no superclass, self types,
      # annotations or members of its own, all of which a reopening declaration may omit.
      def header_copy(source, name, members)
        location = ::RBS::Location.new(shell_buffer, 0, 0)
        if source.is_a?(::RBS::AST::Declarations::Class)
          ::RBS::AST::Declarations::Class.new(
            name: name, type_params: source.type_params, super_class: nil, members: members,
            annotations: [], location: location, comment: nil
          )
        else
          ::RBS::AST::Declarations::Module.new(
            name: name, type_params: source.type_params, members: members, self_types: [],
            annotations: [], location: location, comment: nil
          )
        end
      end

      def rebuild(decl, members:)
        if decl.is_a?(::RBS::AST::Declarations::Class)
          ::RBS::AST::Declarations::Class.new(
            name: decl.name, type_params: decl.type_params, super_class: decl.super_class, members: members,
            annotations: decl.annotations, location: decl.location, comment: decl.comment
          )
        else
          ::RBS::AST::Declarations::Module.new(
            name: decl.name, type_params: decl.type_params, members: members, self_types: decl.self_types,
            annotations: decl.annotations, location: decl.location, comment: decl.comment
          )
        end
      end

      def type_declaration?(decl)
        decl.is_a?(::RBS::AST::Declarations::Class) || decl.is_a?(::RBS::AST::Declarations::Module)
      end

      def qualify(namespace, type_name)
        text = type_name.to_s
        return text.delete_prefix("::") if text.start_with?("::") || namespace.nil?

        "#{namespace}::#{text}"
      end

      # What stood down from each of `roots` in `env`, as `[dir, entries, whole]`: `entries` are
      # `[declaration, cause_file]` pairs, `declaration` reading `Integer#prime?`, `Integer.from_prime_division`
      # or `Prime` (a whole type), `cause_file` the buffer name of the other source's declaration, or nil when it
      # cannot be named. `whole` is true when the directory stood down entirely; its entries are then only the
      # clashes the environment still shows. A directory nothing stood down from is left out.
      #
      # @param roots — `{dir_basename => Pathname}` of the gated directories the run activated.
      def standdowns(env, roots)
        return [] if env.nil?

        loaded = RbsLoader.loaded_signature_buffers(env)&.to_set { |buffer| buffer.name.to_s } || Set.new
        roots.sort.filter_map do |dir, root|
          files = signature_files([root])
          whole = files.none? { |file| loaded.include?(file) }
          entries = files.flat_map { |file| file_standdowns(env, file, whole) }.uniq
          [dir, entries, whole] if whole || !entries.empty?
        end
      rescue ::RBS::BaseError
        []
      end

      def file_standdowns(env, file, whole)
        _buffer, _directives, decls = RbsLoader.parse_signature_file(file)
        return [] if decls.nil?

        entries = []
        each_type(decls, nil) { |decl, name| entries.concat(type_standdowns(env, file, decl, name, whole)) }
        entries
      end

      def each_type(decls, namespace, &block)
        decls.each do |decl|
          next unless type_declaration?(decl)

          name = qualify(namespace, decl.name)
          block.call(decl, name)
          each_type(decl.members, name, &block)
        end
      end

      def type_standdowns(env, file, decl, name, whole)
        entry = env.class_decls[::RBS::TypeName.parse("::#{name}")]
        declarations = entry.nil? ? [] : RbsLoader.entry_declarations(entry)
        vendored = declarations.select { |other| RbsLoader.declaration_buffer_name(other) == file }
        others = declarations.reject { |other| vendored.include?(other) || synthetic?(other) }
        # A partial load shells a type that stood down, so its vendored declaration is gone; a whole stand-down
        # removed every vendored declaration, and only a header the environment still contradicts names a type.
        type_stood_down = whole ? header_conflict?(decl, others) : vendored.empty?
        return [[name, buffer_of(others.first)]] if type_stood_down

        member_standdowns(decl, name, vendored, others, whole)
      end

      def member_standdowns(decl, name, vendored, others, whole)
        present = declared_keys(vendored)
        decl.members.filter_map do |member|
          keys = RbsLoader.member_method_keys(member)
          next if keys.empty? || keys.all? { |key| present.include?(key) }

          cause = others.find { |other| other.members.any? { |m| RbsLoader.member_method_keys(m).intersect?(keys) } }
          next if whole && cause.nil?

          [member_label(name, keys.first), buffer_of(cause)]
        end
      end

      def member_label(name, key)
        method_name, kind = key
        "#{name}#{kind == :singleton ? '.' : '#'}#{method_name}"
      end

      def buffer_of(decl)
        decl && RbsLoader.declaration_buffer_name(decl)
      end
    end
  end
end
