# frozen_string_literal: true

require "spec_helper"
require "digest"
require "fileutils"
require "prism"
require "tmpdir"
require "rigor/inference/scope_indexer"

# ADR-116 WD9 (L1) — `ScopeIndexer::DeclarationSignature` digests one file's declaration surfaces (ADR-89 WD1). The
# digest is opaque, so an example names the parts a file index renders to and compares the answer with the digest of
# exactly those parts: it fails when a part is missing, added, out of order or spelled otherwise. The index is plain
# data built here, with a def node parsed from a line of source where a table holds one; no file is read and nothing
# is indexed. `incremental_session_spec.rb` pins what an edit of a real file does to the signature.
RSpec.describe Rigor::Inference::ScopeIndexer::DeclarationSignature do
  def digest_of(*parts) = Digest::SHA256.hexdigest(parts.join("\x00"))

  # The tables the signature reads with no default. The others (`constant_writes`, the mixin lists,
  # `unpositioned_mixins`, `parameter_envelopes`, `siblings`) may be absent from an index.
  def file_index(**tables)
    { class_sources: {}, superclasses: {}, data_member_layouts: {}, struct_member_layouts: {}, methods: {},
      method_visibilities: {}, def_nodes: {}, singleton_def_nodes: {} }.merge(tables)
  end

  def signature(**tables) = described_class.declaration_signature(file_index(**tables))

  def def_node(source) = Prism.parse(source).value.statements.body.first

  def parameters_of(source) = signature(def_nodes: { "C" => { m: def_node(source) } })

  describe ".declaration_signature" do
    it "is the SHA-256 of the parts joined by a NUL, and of the empty string when the index declares nothing" do
      expect(signature).to eq(Digest::SHA256.hexdigest(""))
      expect(signature(class_sources: { "A" => 1, "B" => 1 })).to eq(Digest::SHA256.hexdigest("c:A\x00c:B"))
    end

    it "renders the surfaces in one order: ancestry, constants, the two method tables, defs, envelopes, certainty" do
      index = {
        class_sources: { "C" => 1 }, constant_writes: { "K" => { "a.rb" => [1] } },
        methods: { "C" => { m: :instance } }, method_visibilities: { "C" => { m: :private } },
        def_nodes: { "C" => { m: def_node("def m; end") } },
        singleton_def_nodes: { "C" => { s: def_node("def self.s; end") } },
        parameter_envelopes: { "C" => { %i[instance m] => [0, 0, false] } },
        siblings: { possible_discovered_methods: { "C" => { m: :instance } } }
      }

      expect(signature(**index)).to eq(
        digest_of("c:C", "k:K=1", "e:C#m=instance", "v:C#m=private", "m:C#m()@1", "m:C.s()@1",
                  "a:C[:instance, :m]=[0, 0, false]", "P:C#m=instance")
      )
    end

    it "names each declared class, superclass and member layout, each table sorted by class name" do
      index = { class_sources: { "B" => 1, "A" => 1 }, superclasses: { "B" => "A", "A" => "Object" },
                data_member_layouts: { "P" => %i[x y], "D" => [] }, struct_member_layouts: { "S" => [:a], "R" => [] } }

      expect(signature(**index)).to eq(
        digest_of("c:A", "c:B", "s:A<Object", "s:B<A", "d:D=[]", "d:P=[:x, :y]", "t:R=[]", "t:S=[:a]")
      )
    end

    # The list order is the file's source order, which an ancestor-order reader consumes, so it is kept; the
    # unpositioned names carry no order, so they are sorted.
    it "keeps a mixin list in its order under its side's tag, between the superclasses and the layouts" do
      index = { superclasses: { "C" => "B" }, includes: { "C" => %w[ModB ModA], "A" => "One" },
                prepends: { "C" => ["Pre"] }, extends: { "C" => %w[Ext Self] }, data_member_layouts: { "C" => [:x] } }

      expect(signature(**index)).to eq(
        digest_of("s:C<B", "i:A=One", "i:C=ModB,ModA", "p:C=Pre", "x:C=Ext,Self", "d:C=[:x]")
      )
    end

    it "names the unpositioned mixins of each class and side, sorted, after the lists" do
      index = { extends: { "C" => ["Ext"] },
                unpositioned_mixins: { "C" => { prepend: ["P"], include: %w[Z *] }, "A" => { extend: ["E"] } } }

      expect(signature(**index)).to eq(
        digest_of("x:C=Ext", "u:A.extend=E", "u:C.include=*,Z", "u:C.prepend=P")
      )
    end

    # A census entry is keyed by path; the signature is one file's, so it reads the entry's one descriptor.
    it "renders a published constant's value, a memo as `||` and an unpublishable write as `?`, sorted by name" do
      writes = { "Z" => { "a.rb" => :unpublishable }, "M" => { "a.rb" => :memo }, "A" => { "a.rb" => [:sym] },
                 "S" => { "a.rb" => ["s"] } }

      expect(signature(constant_writes: writes)).to eq(digest_of("k:A=:sym", "k:M=||", 'k:S="s"', "k:Z=?"))
    end

    it "lists the existence table and then the visibilities, each sorted by class and by slot" do
      index = { methods: { "B" => { z: :instance, a: :singleton }, "A" => { m: :both } },
                method_visibilities: { "B" => { z: :private, %i[singleton a] => :public }, "A" => { m: :protected } } }

      expect(signature(**index)).to eq(
        digest_of("e:A#m=both", "e:B#a=singleton", "e:B#z=instance",
                  "v:A#m=protected", "v:B#[:singleton, :a]=public", "v:B#z=private")
      )
    end

    it "names each def with its parameters and start line, instance defs under `#` and singleton defs under `.`" do
      later = def_node("\n\ndef z(a); end")
      index = { def_nodes: { "B" => { z: later, a: def_node("def a; end") }, "A" => { m: def_node("def m; end") } },
                singleton_def_nodes: { "B" => { s: def_node("\ndef self.s(k:); end") } } }

      expect(signature(**index)).to eq(digest_of("m:A#m()@1", "m:B#a()@1", "m:B#z(r:a)@3", "m:B.s(kr:k)@2"))
    end

    it "labels each parameter by kind and name: required, optional, post, keywords, then the rests and the block" do
      expect(parameters_of("def m(x, y = 1, *rest, z, k:, o: 2, **opts, &blk); end"))
        .to eq(digest_of("m:C#m(r:x,o:y,p:z,kr:k,ko:o,*:rest,**:opts,&:blk)@1"))
    end

    it "labels a nameless or destructuring parameter by its node class" do
      expect(parameters_of("def m(*, **, &); end"))
        .to eq(digest_of("m:C#m(*:RestParameterNode,**:KeywordRestParameterNode,&:BlockParameterNode)@1"))
      expect(parameters_of("def m((a, b), c); end")).to eq(digest_of("m:C#m(r:MultiTargetNode,r:c)@1"))
      expect(parameters_of("def m(...); end")).to eq(digest_of("m:C#m(**:ForwardingParameterNode)@1"))
      expect(parameters_of("def m(**nil); end")).to eq(digest_of("m:C#m(**:NoKeywordsParameterNode)@1"))
    end

    it "renders `()` for a def without parameters, and `()@0` for a table value that is no node" do
      expect(parameters_of("def m; end")).to eq(digest_of("m:C#m()@1"))
      expect(signature(def_nodes: { "C" => { m: Object.new } })).to eq(digest_of("m:C#m()@0"))
    end

    it "lists every envelope entry, sorted by class and then by rendered entry" do
      envelopes = { "B" => { %i[instance z] => :opaque, %i[instance a] => [1, 1, false] },
                    "A" => { "<module>": :opaque } }

      expect(signature(parameter_envelopes: envelopes)).to eq(
        digest_of('a:A:"<module>"=:opaque', "a:B[:instance, :a]=[1, 1, false]", "a:B[:instance, :z]=:opaque")
      )
    end

    it "names each possible method and each contested slot of the siblings, sorted as one list" do
      siblings = { possible_discovered_methods: { "C" => { m: :instance, s: :singleton } },
                   possible_discovered_deferred_ranges: {},
                   contested_discovered_def_nodes: Set[["C", :m]],
                   contested_discovered_singleton_def_nodes: Set[] }

      expect(signature(siblings: siblings)).to eq(
        digest_of('C:contested_discovered_def_nodes:["C", :m]', "P:C#m=instance", "P:C#s=singleton")
      )
    end

    it "is the function the module exposes; the part renderers are private" do
      expect(described_class.singleton_methods(false)).to eq([:declaration_signature])
    end
  end

  # These three came from `scope_indexer_spec.rb`, where they called the part renderers on `ScopeIndexer`. They keep
  # their assertions, and reach the renderers, private here, through `send`.
  describe "the part renderers (ADR-89 WD1)" do
    let(:indexer) { Rigor::Inference::ScopeIndexer }
    let(:tmpdir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(tmpdir) }

    def write(name, body)
      path = File.join(tmpdir, name)
      File.write(path, body)
      path
    end

    it "joins a multi-module include list with a comma (append_ancestry_signature)" do
      path = write("a.rb", <<~RUBY)
        module ModA; end
        module ModB; end

        class Foo
          include ModA
          include ModB
        end
      RUBY
      file_index = indexer.discovered_project_index_for_paths([path]).fetch(:def_index)
      parts = []
      described_class.send(:append_ancestry_signature, parts, file_index)
      # Source order, nearest first: the later `include` searches ahead of the earlier one.
      expect(parts).to include("i:Foo=ModB,ModA")
    end

    it "joins a multi-parameter signature with a comma (parameter_signature)" do
      path = write("a.rb", <<~RUBY)
        class Foo
          def bar(x, y:, z: 1)
            x
          end
        end
      RUBY
      program = Prism.parse(File.read(path)).value
      idx = indexer.index(program, default_scope: Rigor::Scope.empty)
      def_node = idx[program].user_def_for("Foo", :bar)
      expect(described_class.send(:parameter_signature, def_node)).to eq("(r:x,kr:y,ko:z)")
    end

    # Issue #617 — the memo descriptor is rendered apart from an unpublishable write.
    it "renders the memo in the declaration signature apart from an unpublishable write" do
      parts = []
      described_class.send(
        :append_constant_signature,
        parts, constant_writes: { "A" => { "a.rb" => :memo }, "B" => { "a.rb" => :unpublishable } }
      )
      expect(parts).to eq(["k:A=||", "k:B=?"])
    end
  end
end
