# frozen_string_literal: true

require "rbs"

# Reads every member of every `.rbs` under `sig/` into {Declaration}s: the class, method and kind, the
# markers in its RBS comment, and the facts about its signature the provenance gate asks of it (is a
# parameter typed, is the return the bare `untyped`). The classifier ({SigProvenanceAuditor}) decides
# what a declaration IS; this reads what it SAYS.
module SigDeclarationReader
  MARKER_PATTERN = /sig-gen gap:\s*#(?<issue>\d+)\b/
  # A deliberately hand-written row: no engine work would ever let sig-gen answer it, so it gets
  # its own marker rather than a gap pointer with an issue number on the allow-list (#1011).
  AUTHORED_PATTERN = /\bauthored:\s*(?<reason>.*)$/

  Declaration = Struct.new(:path, :line, :class_name, :method_name, :kind, :typed_params, :return_rbs,
                           :marker, :authored_reason, :untyped_return, :types_something, keyword_init: true) do
    def to_s
      "#{path}:#{line}: #{class_name}##{method_name}"
    end
  end

  class << self
    # Every member of every `.rbs` under `sig/`, in file then source order.
    def declarations(root:)
      Dir.glob(File.join(root, "sig/**/*.rbs")).flat_map do |file|
        read_signature(file, file.delete_prefix("#{root}/"))
      end
    end

    private

    def read_signature(file, relative_path)
      buffer = RBS::Buffer.new(name: Pathname(file), content: File.read(file))
      _, _, decls = RBS::Parser.parse_signature(buffer)
      collect(decls, [], relative_path)
    end

    def collect(members, namespace, path)
      members.flat_map do |member|
        case member
        when RBS::AST::Declarations::Class, RBS::AST::Declarations::Module
          nested = namespace + [member.name.to_s.delete_prefix("::")]
          [declaration(member, path, nested.join("::"), nil, nil)] + collect(member.members, nested, path)
        when RBS::AST::Members::MethodDefinition
          [declaration(member, path, namespace.join("::"), member.name.to_s, member.kind,
                       typed_params: typed_params?(member.overloads),
                       return_rbs: return_rbs(member.overloads))]
        when RBS::AST::Members::AttrReader, RBS::AST::Members::AttrWriter,
             RBS::AST::Members::AttrAccessor
          attribute_declarations(member, path, namespace.join("::"))
        else
          [declaration(member, path, namespace.join("::"), member_label(member), nil)]
        end
      end
    end

    ATTR_NAMES = {
      RBS::AST::Members::AttrReader => ->(name) { [name.to_s] },
      RBS::AST::Members::AttrWriter => ->(name) { ["#{name}="] },
      RBS::AST::Members::AttrAccessor => ->(name) { [name.to_s, "#{name}="] }
    }.freeze
    private_constant :ATTR_NAMES

    def attribute_declarations(member, path, class_name)
      ATTR_NAMES.fetch(member.class).call(member.name).map do |name|
        # A writer's parameter type is its attribute type, so a non-`untyped` attribute makes the
        # writer parameter-intent; the reader's own signature takes no parameter at all.
        typed = name.end_with?("=") && !untyped?(member.type)
        declaration(member, path, class_name, name, member.kind, typed_params: typed,
                                                                 return_rbs: member.type.to_s)
      end
    end

    def declaration(member, path, class_name, method_name, kind, typed_params: false, return_rbs: nil)
      Declaration.new(path: path, line: member.location&.start_line, class_name: class_name,
                      method_name: method_name, kind: kind, typed_params: typed_params,
                      return_rbs: return_rbs, untyped_return: untyped_return?(member),
                      types_something: types_something_of?(member, typed_params), marker: marker_for(member),
                      authored_reason: authored_for(member))
    end

    # A member with no name of its own (`include`, `alias`, an instance-variable declaration) is
    # reported by its member class so the audit's `non_method` rows stay legible.
    def member_label(member)
      return member.name.to_s if member.respond_to?(:name) && member.name

      member.class.name.split("::").last.downcase
    end

    def marker_for(member)
      text = member.respond_to?(:comment) ? member.comment&.string : nil
      match = text && MARKER_PATTERN.match(text)
      match && match[:issue]
    end

    def authored_for(member)
      text = member.respond_to?(:comment) ? member.comment&.string : nil
      match = text && AUTHORED_PATTERN.match(text)
      match && match[:reason]&.strip
    end

    def typed_params?(overloads)
      overloads.any? do |overload|
        function = overload.method_type.type
        next true if function.is_a?(RBS::Types::UntypedFunction)

        overload.method_type.block || function_parameters(function).any? { |p| !untyped?(p.type) }
      end
    end

    # Overloads are joined with ` | ` so a multi-overload member reads as one spelling; the only
    # comparison made against it is the exact `"void"` of a constructor, which has one overload.
    def return_rbs(overloads)
      overloads.map { |overload| overload.method_type.type.return_type.to_s }.uniq.join(" | ")
    end

    # Every overload's own return is the bare `untyped` (the same test as `Generator#declared_untyped?`): not
    # `[untyped, untyped]`, `Array[untyped]`, `untyped?`, a union with `untyped`, nor an interface return.
    # An attribute's return is its declared type.
    def untyped_return?(member)
      return untyped?(member.type) if member.respond_to?(:type)
      return false unless member.respond_to?(:overloads) && member.overloads.any?

      member.overloads.all? { |overload| untyped?(overload.method_type.type.return_type) }
    end

    # Whether the declaration states any type at all, for `parameter_only` (a stricter test than {typed_params?},
    # which `parameter_intent` keeps): not `(?)`, and some positional, optional, rest, keyword or keyword-rest
    # parameter is not `untyped`, or the block's own parameters or its declared return are not. A block's return
    # says what the caller's block must return, which is authored intent like a parameter.
    def types_something_of?(member, typed_params)
      member.respond_to?(:overloads) ? types_something?(member.overloads) : typed_params
    end

    def types_something?(overloads)
      overloads.any? do |overload|
        function = overload.method_type.type
        next false if function.is_a?(RBS::Types::UntypedFunction)

        function_types_something?(function) || block_types_something?(overload.method_type.block)
      end
    end

    def function_types_something?(function)
      function_parameters(function).any? { |p| !untyped?(p.type) }
    end

    def block_types_something?(block)
      return false if block.nil? || block.type.is_a?(RBS::Types::UntypedFunction)

      function_types_something?(block.type) || !untyped?(block.type.return_type)
    end

    def function_parameters(function)
      function.required_positionals + function.optional_positionals +
        function.trailing_positionals + function.required_keywords.values +
        function.optional_keywords.values +
        [function.rest_positionals, function.rest_keywords].compact
    end

    def untyped?(type) = type.is_a?(RBS::Types::Bases::Any)
  end
end
