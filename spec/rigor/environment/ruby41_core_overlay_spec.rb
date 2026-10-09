# frozen_string_literal: true

require "tmpdir"

# Issues #1691 and #1718 — the core overlay's Ruby 4.1 entries build on every rbs line, and stand down for a later
# declaration.
#
# No rbs release through 4.2 declares Ruby 4.1's new core methods, so `data/core_overlay/` does. Two ways that could
# go wrong silently, since Rigor fails soft to `Dynamic[top]` for a class whose definition does not build:
#
# * an overlay that does not build on one rbs line (an alias that line lacks, a `RecursiveAncestorError` from a
#   module `Kernel` includes) takes the whole class down, with every real method and typo in it;
# * a later rbs release, or a project `sig/` written for Steep, that declares the same method directly would be a
#   `DuplicatedMethodDefinitionError` against a direct overlay `def`. The overlay therefore declares each method on a
#   module the class includes, which a direct `def` overrides.
#
# This file lives under `spec/rigor/environment` because that is what CI's "RBS compatibility (RBS 3.x)" job runs.
require "spec_helper"

RSpec.describe "Ruby 4.1 core overlay (#1691, #1718)" do
  # `[class, kind, methods, overlay file]` for every declaration the 4.1 entries add.
  declarations = [
    ["Integer", :instance, %i[bit_count], "integer.rbs"],
    ["String", :instance,
     %i[bit_get bit_set? bit_set bit_clear bit_flip bit_count bitwise_not bitwise_not! bitwise_and bitwise_and!
        bitwise_or bitwise_or! bitwise_xor bitwise_xor!], "string.rbs"],
    ["Range", :instance, %i[clamp], "range.rbs"],
    ["MatchData", :instance, %i[integer_at], "match_data.rbs"],
    ["Module", :instance, %i[descendants autoload_relative], "module.rbs"],
    ["Class", :instance, %i[descendants], "module.rbs"],
    ["Kernel", :instance, %i[autoload_relative], "kernel.rbs"],
    ["Kernel", :singleton, %i[autoload_relative], "kernel.rbs"],
    ["RBS::Unnamed::ENVClass", :instance, %i[fetch_values], "env.rbs"],
    ["Thread::Backtrace::Location", :instance, %i[source_range], "source_range.rbs"],
    ["Proc", :instance, %i[source_range], "source_range.rbs"],
    ["Method", :instance, %i[source_range], "source_range.rbs"],
    ["UnboundMethod", :instance, %i[source_range], "source_range.rbs"],
    ["IO::Buffer", :instance, %i[bit_count], "io_buffer.rbs"],
    ["Ruby::SourceRange", :instance,
     %i[path absolute_path start_line start_column end_line end_column], "source_range.rbs"]
  ].freeze

  def definition(loader, class_name, kind)
    kind == :instance ? loader.instance_definition(class_name) : loader.singleton_definition(class_name)
  end

  def declaring_files(method)
    method.defs.map { |d| File.basename(d.member.location.buffer.name.to_s) }.uniq
  end

  describe "the bundled environment" do
    let(:loader) { Rigor::Environment::RbsLoader.new(libraries: []) }

    declarations.each do |class_name, kind, methods, file|
      it "declares #{class_name} #{kind} #{methods.join(', ')} from #{file}" do
        methods_table = definition(loader, class_name, kind)&.methods
        expect(methods_table).not_to be_nil, "#{class_name} did not build"

        methods.each do |name|
          expect(methods_table[name]).not_to be_nil, "#{class_name}##{name} is not declared"
          expect(declaring_files(methods_table[name])).to eq([file])
        end
      end
    end

    # The `Kernel` include is the one that can cycle: `Object` includes `Kernel`, so a module `Kernel` includes
    # whose self type is the default `Object` is a `RecursiveAncestorError` for `Object` and every class under it.
    it "keeps Object and BasicObject buildable" do
      expect(loader.instance_definition("Object")&.methods).to include(:autoload_relative, :puts)
      expect(loader.instance_definition("BasicObject")).not_to be_nil
    end

    # #1718. `global:` is an optional keyword, so the arity rule still reads these methods; `scope:` is required, so
    # a call without it still selects the upstream `GC.stat` arms.
    it "adds the global: and scope: keywords to the upstream GC and ObjectSpace overloads" do
      keyword_arms = lambda do |definition, name, keyword, required:|
        definition.methods[name].method_types.select do |method_type|
          keywords = required ? method_type.type.required_keywords : method_type.type.optional_keywords
          keywords.key?(keyword)
        end
      end
      gc = loader.singleton_definition("GC")
      expect(keyword_arms.call(gc, :start, :global, required: false).size).to eq(1)
      expect(keyword_arms.call(gc, :stat, :scope, required: true).size).to eq(1)
      expect(gc.methods[:stat].method_types.size).to be > 1
      [
        loader.instance_definition("GC"), loader.singleton_definition("ObjectSpace"),
        loader.instance_definition("ObjectSpace")
      ].each do |definition|
        expect(keyword_arms.call(definition, :garbage_collect, :global, required: false).size).to eq(1)
      end
    end

    it "adds the three-argument method_defined? and the Hash form of tr / tr! to the upstream overloads" do
      method_defined = loader.instance_definition("Module").methods[:method_defined?]
      arities = method_defined.method_types.map do |method_type|
        method_type.type.required_positionals.size + method_type.type.optional_positionals.size
      end
      expect(arities).to include(2, 3)

      string = loader.instance_definition("String").methods
      %i[tr tr!].each do |name|
        overloads = string[name].method_types.map(&:to_s)
        expect(overloads).to include(a_string_including("Hash[")).and(have_attributes(size: 2))
      end
    end
  end

  # A direct declaration from elsewhere — what a later rbs release or a project `sig/` written for Steep carries —
  # overrides the overlay's module method instead of colliding with it.
  describe "a direct declaration of the same methods" do
    let(:sig_dir) { Dir.mktmpdir("rigor-ruby41-overlay-") }
    let(:loader) { Rigor::Environment::RbsLoader.new(libraries: [], signature_paths: [sig_dir]) }

    before do
      File.write(File.join(sig_dir, "ruby41.rbs"), <<~RBS)
        class Integer
          def bit_count: () -> Integer
        end
        class String
          def bitwise_and: (String other) -> String
        end
        class Range[out Elem]
          def clamp: (untyped min, untyped max) -> Range[Elem]
        end
        module Kernel
          def self?.autoload_relative: (Symbol const, String filename) -> nil
        end
        class Module
          def descendants: () -> Array[Module]
        end
        class IO::Buffer
          def bit_count: () -> Integer
        end
        module Ruby
          class SourceRange < Object
            def path: () -> String
          end
        end
      RBS
    end

    after { FileUtils.remove_entry(sig_dir) }

    [
      ["Integer", :instance, :bit_count],
      ["String", :instance, :bitwise_and],
      ["Range", :instance, :clamp],
      ["Kernel", :instance, :autoload_relative],
      ["Kernel", :singleton, :autoload_relative],
      ["Module", :instance, :descendants],
      ["Ruby::SourceRange", :instance, :path],
      ["IO::Buffer", :instance, :bit_count]
    ].each do |class_name, kind, name|
      it "builds #{class_name} and answers #{kind} #{name} from the direct declaration" do
        methods_table = definition(loader, class_name, kind)&.methods
        expect(methods_table).not_to be_nil, "#{class_name} did not build"
        expect(declaring_files(methods_table[name])).to eq(["ruby41.rbs"])
      end
    end

    it "still answers the overlay's other methods on an overridden class" do
      expect(loader.instance_definition("String").methods).to include(:bitwise_or, :bit_get)
      expect(loader.instance_definition("Ruby::SourceRange").methods).to include(:start_line)
    end
  end
end
