# frozen_string_literal: true

require "prism"

module Rigor
  # {Reflection}'s per-file declaration walk for plugins (ADR-128, #2708): {.class_declarations_in} answers which
  # classes a parsed file declares under their `Module.nesting`-correct names, and hands each call the walk visits
  # to a plugin together with the class or module its position reaches. It replaces a plugin's own
  # `DeclarationWalk::Collector`, so the walk's context, its control constants and its collector protocol stay
  # internal.
  module Reflection
    # One `class` header of a file, as {.class_declarations_in} reports it.
    #
    # - `name` — the qualified name the header's body is keyed under (`"Admin::User"` for `class User` in
    #   `module Admin`, and for `class Admin::User`); never empty.
    # - `nesting` — `Module.nesting` where the header is written, innermost first, not counting the class itself
    #   (`["Admin"]` for `class User` in `module Admin`; `[]` at the top level). Frozen.
    # - `node` — the `Prism::ClassNode`, for its `superclass` and `body`.
    ClassDeclaration = Data.define(:name, :nesting, :node)

    # One call the walk visited, as {.class_declarations_in} yields it.
    #
    # - `node` — the `Prism::CallNode`.
    # - `owner` — the qualified name of the innermost `class` / `module` the call is lexically inside, or nil where
    #   none is (the top level, or below a bare header in a `class << self` body).
    DeclaredCall = Data.define(:node, :owner)

    module_function

    # ADR-128, #2708 — the classes a parsed file declares, in the order their headers are written. A class
    # reopened in the file appears once per header. A `module`, a `class << self` and a class no name reaches
    # (`Class.new { … }`, a header below `class << self`) are not reported.
    #
    # With a block, the walk also yields a {DeclaredCall} for the calls the engine's declaration walk visits, in
    # source order, outer calls before the calls inside them. Those are the calls in statements and in the bodies of
    # `class` / `module` / `class << self` / blocks, at any depth. The owner is lexical, not `self`: a call in
    # `class << self` or in a `Class.new { … }` block reports the class around it.
    #
    # The block does not see every call node of the file. The walk does not enter, so the block never sees:
    #
    # - a class or module header's own expressions: the superclass (`class Foo < Struct.new(:a)`) and the constant
    #   path (`class foo::Bar`);
    # - the factory call a constant write binds (`K = Class.new { … }`), whose receiver, arguments and block body the
    #   walk does enter;
    # - the tail of such a write (`K = Class.new { … }.freeze` yields what is inside the block, not `freeze`), and
    #   the constant-path parent of a write target (`P` in `P::K = …`).
    #
    # `root` is a `Prism::Node`, typically `Prism.parse(source).value`.
    def class_declarations_in(root, &on_call)
      # Loaded on first use, not with `Reflection`: the walk heads the analysis engine, which the engine-free
      # paths (a warm `rigor effects`) load `Reflection` without. The walk's entry point loads the collectors.
      require_relative "../inference/declaration_walk"
      collector = on_call ? DeclarationCallCollector.new(on_call) : DeclarationCollector.new
      Inference::DeclarationWalk.run(root, [collector], Inference::DeclarationWalk::Context.root(nesting: []))
      collector.classes
    end
  end
end
