# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Issues #2230 and #2224 — the spelling sig-gen gives a core class in what it writes. Each example runs the
# generator and the writer over a fixture project and checks the written `sig/` with `RBS::Validator` and the
# definition builder, over the core signatures plus the project's own.
RSpec.describe Rigor::SigGen::Generator do
  let(:tmpdir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(tmpdir) }

  def configuration
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => ["lib"], "signature_paths" => ["sig"])
    )
  end

  # Writes `files` (relative path => contents) under the fixture root, runs `sig-gen --write` there, and returns
  # the generated `sig/<name>.rbs` for `lib/<name>.rb`.
  def generate(files, name:)
    files.each do |rel, contents|
      full = File.join(tmpdir, rel)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, contents)
    end
    Dir.chdir(tmpdir) do
      candidates = described_class.new(configuration: configuration, paths: ["lib"]).run
      mapper = Rigor::SigGen::PathMapper.new(configuration: configuration, project_root: tmpdir)
      Rigor::SigGen::Writer.new(path_mapper: mapper).write_all(candidates)
    end
    File.read(File.join(tmpdir, "sig/#{name}.rbs"))
  end

  # What `rbs validate` would reject in the fixture's `sig/`: each declaration's ancestry and member types, as
  # error classes.
  def validation_errors
    loader = RBS::EnvironmentLoader.new
    loader.add(path: Pathname(File.join(tmpdir, "sig")))
    env = RBS::Environment.from_loader(loader).resolve_type_names
    builder = RBS::DefinitionBuilder.new(env: env)
    validator = RBS::Validator.new(env: env, resolver: RBS::Resolver::TypeNameResolver.build(env))
    project_class_entries(env).flat_map { |name, entry| declaration_errors(name, entry, builder, validator) }
  end

  def project_class_entries(env)
    env.class_decls.select do |_name, entry|
      entry.each_decl.any? { |decl| decl.location.buffer.name.to_s.start_with?(tmpdir) }
    end
  end

  def declaration_errors(name, entry, builder, validator)
    errors = []
    [:build_instance, :build_singleton].each do |build|
      builder.public_send(build, name)
    rescue RBS::BaseError => e
      errors << e.class
    end
    entry.each_decl do |decl|
      decl.members.grep(RBS::AST::Members::MethodDefinition).each do |member|
        member.overloads.each do |overload|
          overload.method_type.each_type { |type| validator.validate_type(type, context: nil) }
        rescue RBS::BaseError => e
          errors << e.class
        end
      end
    end
    errors
  end

  describe "a core type name a namespace shadows (#2230)" do
    it "anchors a generic core name the owner's own namespace declares" do
      written = generate(
        {
          "lib/foo.rb" => "require \"set\"\nmodule Foo\n  class Set; end\n  def self.make = ::Set[1]\nend\n",
          "sig/foo_set.rbs" => "class Foo::Set\nend\n"
        },
        name: "foo"
      )

      expect(written).to include("def self.make: () -> ::Set[untyped]")
      expect(validation_errors).to be_empty
    end

    it "anchors a non-generic core name, which would otherwise type the method as the project class" do
      written = generate(
        {
          "lib/foo.rb" => "module Foo\n  class Integer; end\n  def self.num = rand(10)\nend\n",
          "sig/foo_integer.rbs" => "class Foo::Integer\nend\n"
        },
        name: "foo"
      )

      expect(written).to include("def self.num: () -> ::Integer")
      expect(validation_errors).to be_empty
    end

    it "anchors a name an enclosing namespace shadows" do
      written = generate(
        {
          "lib/outer.rb" => <<~RUBY,
            require "set"
            module Outer
              class Set; end
              class Inner
                def make = ::Set[1]
              end
            end
          RUBY
          "sig/outer_set.rbs" => "class Outer::Set\nend\n"
        },
        name: "outer"
      )

      expect(written).to include("def make: () -> ::Set[untyped]")
      expect(validation_errors).to be_empty
    end

    it "anchors the name when only `sig/` declares the shadowing class" do
      written = generate(
        {
          "lib/foo.rb" => "require \"set\"\nmodule Foo\n  def self.make = ::Set[1]\nend\n",
          "sig/foo_set.rbs" => "class Foo::Set\nend\n"
        },
        name: "foo"
      )

      expect(written).to include("def self.make: () -> ::Set[untyped]")
      expect(validation_errors).to be_empty
    end

    it "anchors the name when only the source declares the shadowing class" do
      written = generate(
        { "lib/foo.rb" => "require \"set\"\nmodule Foo\n  class Set; end\n  def self.make = ::Set[1]\nend\n" },
        name: "foo"
      )

      expect(written).to include("def self.make: () -> ::Set[untyped]")
      expect(validation_errors).to be_empty
    end

    it "keeps the unqualified spelling where nothing shadows the name" do
      written = generate(
        { "lib/bar.rb" => "require \"set\"\nmodule Bar\n  def self.make = ::Set[1]\n  def self.num = rand(10)\nend\n" },
        name: "bar"
      )

      expect(written).to include("def self.make: () -> Set[untyped]", "def self.num: () -> Integer")
      expect(validation_errors).to be_empty
    end
  end

  describe "an empty subclass of a core class (#2224)" do
    let(:source) do
      <<~RUBY
        require "set"
        class MyHash < Hash; end
        class MyArray < Array; end
        class MySet < Set; end
        class MyStruct < Struct; end
        class Maker
          def hash_ = MyHash.new
          def array_ = MyArray.new
          def set_ = MySet.new
          def struct_ = MyStruct
        end
      RUBY
    end

    it "declares each one with its superclass's type arguments, so a method returning it resolves" do
      written = generate({ "lib/subs.rb" => source }, name: "subs")

      expect(written).to include(
        "class MyHash < ::Hash[untyped, untyped]\nend",
        "class MyArray < ::Array[untyped]\nend",
        "class MySet < ::Set[untyped]\nend",
        "class MyStruct < ::Struct[untyped]\nend",
        "def hash_: () -> MyHash"
      )
      expect(validation_errors).to be_empty
    end

    it "declares a non-generic one bare" do
      written = generate(
        { "lib/errors.rb" => "class MyError < StandardError; end\nclass Raiser\n  def err = MyError.new\nend\n" },
        name: "errors"
      )

      expect(written).to include("class MyError < ::StandardError\nend")
      expect(validation_errors).to be_empty
    end

    it "leaves a class another signature already declares to that declaration" do
      written = generate(
        { "lib/subs.rb" => source, "sig/my_hash.rbs" => "class MyHash < ::Hash[untyped, untyped]\nend\n" },
        name: "subs"
      )

      expect(written).not_to include("class MyHash")
      expect(written).to include("class MyArray < ::Array[untyped]")
      expect(validation_errors).to be_empty
    end

    # A guard on the issue's scope: a subclass of a project class keeps the pre-#2224 output.
    it "declares no empty subclass of a project class" do
      written = generate(
        { "lib/base.rb" => "class Base\n  def x = 1\nend\nclass Sub < Base; end\nclass Maker\n  def s = 1\nend\n" },
        name: "base"
      )

      expect(written).not_to include("class Sub")
    end

    # A guard: the shadowed superclass is the project's own, which is not this issue's case.
    it "declares no subclass whose superclass name the header's nesting shadows" do
      written = generate(
        {
          "lib/foo.rb" => <<~RUBY
            module Foo
              class Hash; end
              class MyHash < Hash; end
              def self.make = 1
            end
          RUBY
        },
        name: "foo"
      )

      expect(written).not_to include("MyHash")
    end
  end
end
