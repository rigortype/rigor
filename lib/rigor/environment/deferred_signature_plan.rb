# frozen_string_literal: true

require "rbs"

module Rigor
  class Environment
    # Issue #2422 — what a bundled plugin's deferred signature file loads as, against the environment every other
    # signature source has already built. The #610 arity check stands a file down whole first
    # (`RbsLoader.generic_arity_conflict`); {.plan} decides the rest declaration by declaration and member by
    # member, with {GatedSignaturePlan}'s #1713 helpers:
    #
    # - a method another source declares (a `def`, an attribute or an alias), where that source is NOT the project's own
    #   (an `rbs collection install`, a gem's `sig/`, a vendored or another plugin's file), is *composed*: the plugin's
    #   `def` becomes an overload continuation, `def m: <plugin overloads> | ...`, so RBS puts the plugin's overloads
    #   first and keeps the other source's as the fallback. The plugin's signatures are often written wider on purpose
    #   (`Object#html_safe?: () -> bool` where the collection says `-> false`), and standing them down would let the
    #   narrower one fold correct code into dead branches;
    # - any other method, attribute or alias another source declares stands down: the project's own `sig/` or
    #   inline RBS binds by #610's rule, and an attribute, an alias or one side of a `def self?.m` cannot be
    #   continued ({GatedSignaturePlan.untaken} narrows an `attr_accessor` or `self?` to its untaken half);
    # - a constant, global, type alias, interface or class alias another source already declares, and a type
    #   whose kind (class or module) contradicts another source's, stands down on its own, where adding it would
    #   have raised `RBS::DuplicatedDeclarationError` and dropped the plugin's whole file;
    # - a class header's superclass clause another source already gives the class one stands down (#2439), where two
    #   different clauses would have raised `RBS::SuperclassMismatchError`; the plugin's declaration reopens the class.
    #
    # A declaration with nothing taken comes back as the same object, so a file with no collision loads as it
    # stands. {.standdown_rows} reads what stood down back off the built environment, so a warm run off the env
    # cache reports what the cold run decided.
    module DeferredSignaturePlan
      module_function

      # @param own — the buffer names that are the project's own sources: its `signature_paths:` files (not the
      #   collection or gem directories also on that list) and its inline RBS.
      def plan(decls, env, own, namespace = nil)
        planned = decls.filter_map { |decl| plan_declaration(decl, env, own, namespace) }
        same?(planned, decls) ? decls : planned
      end

      def plan_declaration(decl, env, own, namespace)
        name = GatedSignaturePlan.qualify(namespace, declared_name(decl))
        if GatedSignaturePlan.type_declaration?(decl)
          return nil if kind_clash?(env, decl, name)

          return plan_type(decl, env, own, name)
        end
        declared_elsewhere(env, decl, name) ? nil : decl
      end

      def plan_type(decl, env, own, name)
        others = GatedSignaturePlan.other_declarations(env, name)
        taken = GatedSignaturePlan.declared_keys(others)
        external = others.reject { |other| own.include?(buffer_of(other)) }
        defined = GatedSignaturePlan.declared_keys(external) | definition_keys(external)
        members = decl.members.filter_map do |member|
          next plan_declaration(member, env, own, name) if declaration?(member)
          next member if taken.empty?

          composed(member, defined) || GatedSignaturePlan.untaken(member, taken)
        end
        drop = superclass_given?(decl, others)
        return decl if same?(members, decl.members) && !drop

        GatedSignaturePlan.rebuild(decl, members: members, drop_super_class: drop)
      end

      # Issue #2439 — true when `decl` is a class with a superclass clause and another source (`others`) already
      # gives the class one. Two different clauses raise `RBS::SuperclassMismatchError` and the class and every
      # descendant read `Dynamic[top]`, so the plugin's header stands down and reopens the class without one. The
      # two names are not compared: they are not resolved yet, and the other source's superclass binds either way.
      def superclass_given?(decl, others)
        super_class?(decl) && others.any? { |other| super_class?(other) }
      end

      # `member` as an overload continuation, or nil when it cannot be one: only a plain one-sided `def` can, and
      # only onto a method — a `def`, an attribute or an alias, all of which RBS continues — that a source other
      # than the project's own declares.
      def composed(member, defined)
        return nil unless member.is_a?(::RBS::AST::Members::MethodDefinition) && !member.overloading?
        return nil if member.kind == :singleton_instance

        key = [member.name, member.kind]
        return nil unless defined.include?(key)

        member.update(overloading: true)
      end

      # The `[name, kind]` keys a plain or continued `def` in `decls` declares — what a continuation can extend.
      def definition_keys(decls)
        decls.each_with_object(Set.new) do |decl, keys|
          decl.members.each do |member|
            next unless member.is_a?(::RBS::AST::Members::MethodDefinition)

            sides = member.kind == :singleton_instance ? %i[instance singleton] : [member.kind]
            sides.each { |side| keys << [member.name, side] }
          end
        end
      end

      def kind_clash?(env, decl, name)
        type_name = ::RBS::TypeName.parse("::#{name}")
        return true if env.class_alias_decls.key?(type_name)

        first = GatedSignaturePlan.other_declarations(env, name).first
        !first.nil? && !first.instance_of?(decl.class)
      end

      # The buffer of the declaration another source already makes under `decl`'s name, or nil.
      def declared_elsewhere(env, decl, name)
        entry = declaration_entry(env, decl, name)
        entry && (RbsLoader.declaration_buffer_name(entry.decl) || "")
      end

      def declaration_entry(env, decl, name)
        type_name = -> { ::RBS::TypeName.parse("::#{name}") }
        case decl
        when ::RBS::AST::Declarations::Constant then env.constant_decls[type_name.call]
        when ::RBS::AST::Declarations::Global then env.global_decls[decl.name]
        when ::RBS::AST::Declarations::TypeAlias then env.type_alias_decls[type_name.call]
        when ::RBS::AST::Declarations::Interface then env.interface_decls[type_name.call]
        when ::RBS::AST::Declarations::ClassAlias, ::RBS::AST::Declarations::ModuleAlias
          env.class_alias_decls[type_name.call] || env.class_decls[type_name.call]
        end
      end

      # A class or module alias names itself as `new_name`; every other declaration as `name`.
      def declared_name(decl)
        decl.respond_to?(:new_name) ? decl.new_name : decl.name
      end

      def declaration?(member)
        member.is_a?(::RBS::AST::Declarations::Base)
      end

      def same?(planned, original)
        planned.size == original.size && planned.zip(original).all? { |a, b| a.equal?(b) }
      end

      def buffer_of(decl)
        RbsLoader.declaration_buffer_name(decl)
      end

      # What {.plan} left out of the deferred `file` (its parsed `decls`) in the built `env`, as `[declaration,
      # cause_file]` rows — `Object#acts_like?`, `Time.at`, `FFI::Pointer::NULL`, or a type name — with the buffer
      # of the other source's declaration, or nil when it cannot be named. A composed method is not a row: the
      # plugin's overloads still bind.
      def standdown_rows(env, file, decls)
        rows = []
        decls.each { |decl| declaration_rows(env, file, decl, nil, rows) }
        rows.uniq
      end

      def declaration_rows(env, file, decl, namespace, rows)
        name = GatedSignaturePlan.qualify(namespace, declared_name(decl))
        return type_rows(env, file, decl, name, rows) if GatedSignaturePlan.type_declaration?(decl)

        cause = displaced_by(env, decl, name, file)
        rows << [decl.is_a?(::RBS::AST::Declarations::Global) ? decl.name.to_s : name, cause] if cause
      end

      # A non-nil buffer name (possibly empty) when another source's declaration of `decl` is the one loaded.
      def displaced_by(env, decl, name, file)
        entry = declaration_entry(env, decl, name)
        return nil if entry.nil?

        buffer = RbsLoader.declaration_buffer_name(entry.decl)
        buffer == file ? nil : buffer
      end

      def type_rows(env, file, decl, name, rows)
        entry = env.class_decls[::RBS::TypeName.parse("::#{name}")]
        declarations = entry.nil? ? [] : RbsLoader.entry_declarations(entry)
        loaded = declarations.select { |other| buffer_of(other) == file }
        others = declarations.reject { |other| loaded.include?(other) || GatedSignaturePlan.synthetic?(other) }
        if loaded.empty?
          cause = others.empty? ? alias_cause(env, name) : buffer_of(others.first)
          rows << [name, cause] if cause
          return
        end

        rows.concat(superclass_rows(env, decl, name, loaded, others))
        rows.concat(member_rows(decl, name, loaded, others))
        decl.members.each { |member| declaration_rows(env, file, member, name, rows) if declaration?(member) }
      end

      # The buffer of a class or module alias declaring `name` (empty when it cannot be named), or nil.
      def alias_cause(env, name)
        entry = env.class_alias_decls[::RBS::TypeName.parse("::#{name}")]
        entry && (RbsLoader.declaration_buffer_name(entry.decl) || "")
      end

      # The plugin's superclass clause as a row (`ActiveRecord::StatementInvalid < ActiveRecordError`) when every
      # declaration the file loaded for the class lost it to another source's ({.superclass_given?}) and that
      # source names a different class. The plan drops a matching clause too, but nothing is lost, so no row.
      def superclass_rows(env, decl, name, loaded, others)
        return [] unless superclass_given?(decl, others) && loaded.none? { |kept| super_class?(kept) }

        cause = others.find { |other| super_class?(other) }
        return [] if resolved_super_class(env, decl.super_class.name, name) == cause.super_class.name.to_s

        [["#{name} < #{decl.super_class.name}", buffer_of(cause)]]
      end

      # `written` (a superclass name as the plugin spells it) as the absolute name it reads in `env`: the first
      # namespace enclosing `class_name`, innermost first, under which its leading segment is a declared class,
      # module or alias. The built env's names are already absolute, so this is only what the report compares.
      def resolved_super_class(env, written, class_name)
        return written.to_s if written.absolute?

        head = written.to_s.split("::").first
        prefixes = class_name.split("::")[0...-1]
        prefixes.size.downto(0) do |size|
          prefix = prefixes.first(size).map { |segment| "::#{segment}" }.join
          candidate = ::RBS::TypeName.parse("#{prefix}::#{head}")
          return "#{prefix}::#{written}" if env.class_decls.key?(candidate) || env.class_alias_decls.key?(candidate)
        end
        "::#{written}"
      end

      def super_class?(decl)
        decl.is_a?(::RBS::AST::Declarations::Class) && !decl.super_class.nil?
      end

      def member_rows(decl, name, loaded, others)
        present = GatedSignaturePlan.declared_keys(loaded) | definition_keys(loaded)
        decl.members.flat_map do |member|
          RbsLoader.member_method_keys(member).reject { |key| present.include?(key) }.filter_map do |key|
            cause = others.find { |other| other.members.any? { |m| RbsLoader.member_method_keys(m).include?(key) } }
            cause && [GatedSignaturePlan.member_label(name, key), buffer_of(cause)]
          end
        end
      end
    end
  end
end
