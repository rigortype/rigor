# frozen_string_literal: true

require "spec_helper"
require "prism"

# ADR-116 C4 — `CallLadder::TopLevelDef` is the `top_level_def` rung of the call ladder: an implicit-self call of a
# name the project defines as a top-level `def`, answered from that `def`'s body where the call's own `self` does not
# answer the name. The examples index a snippet, build the site the typer would (at top level the receiver is the
# `Object` stand-in `ExpressionTyper#call_receiver_type_for` gives), and ask the module with a real typer over the
# scope of the call. The module reads `typer.scope` and calls back `positional_correspondence`,
# `infer_user_method_return` and `resolve_user_def_through_ancestors`; what a body types as is
# `infer_user_method_return`'s. Which blocks the #316 gate declines a bind in is
# `toplevel_def_in_self_preserving_block_spec.rb`'s, and which plugin members veto one
# `plugin_member_over_toplevel_def_spec.rb`'s; here a scope stands in for each (a def from another file under an
# unmodelled `self`, and an ADR-16 synthetic member).
RSpec.describe Rigor::Inference::CallLadder::TopLevelDef do
  let(:combinator) { Rigor::Type::Combinator }
  let(:program) do
    Prism.parse(<<~RUBY).value
      def helper = "top"
      def twice(n) = n
      def each_top = yield
      def me = self
      def label = "top"
      class Box
        def helper = "box"
        def probe
          helper
          twice(1)
        end
        def self.label = :box
        def self.build
          label
          helper
        end
      end
      Line = Struct.new(:twice) do
        def probe = twice(2)
      end
      def email = "top"
      class Account
        def probe
          other
        end
      end
      helper
      twice(3)
      each_top { :seen }
      send(:helper)
      Box.new.helper
      me
    RUBY
  end
  let(:statements) { program.statements.body }
  # A plugin's synthetic `Account#email`, which Ruby reaches ahead of the top-level `def email`.
  let(:environment) do
    email = Rigor::Inference::SyntheticMethod.new(class_name: "Account", method_name: :email, return_type: "untyped",
                                                  kind: :instance, provenance: {})
    Rigor::Environment.for_project(synthetic_method_index: Rigor::Inference::SyntheticMethodIndex.new(entries: [email]))
  end
  let(:index) do
    Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty(environment: environment))
  end
  let(:box) { statements[5].body.body }
  let(:object) { combinator.nominal_of("Object") }

  # The site of the implicit-self call `node`, typed from the scope it is written in, or from `scope`.
  def site(method_name, node, args: [], receiver: nil, block_type: nil, scope: index.fetch(node))
    receiver ||= scope.self_type || object
    cc(receiver: receiver, method_name: method_name, args: args, block_type: block_type,
       environment: scope.environment, call_node: node, scope: scope)
  end

  def answer(method_name, node, scope: index.fetch(node), **)
    typer = Rigor::Inference::ExpressionTyper.new(scope: scope)
    described_class.try_call(site(method_name, node, scope: scope, **), typer)
  end

  describe ".try_call" do
    it "types an implicit-self call at top level from the top-level def's body" do
      expect(index.fetch(statements[9]).self_type).to be_nil
      expect(answer(:helper, statements[9]).describe).to eq('"top"')
      expect(answer(:twice, statements[10], args: [combinator.constant_of(3)]).describe).to eq("3")
    end

    # A literal `send`'s target is a site whose node is the `send`: `send(:helper)` is named `send`, and its site is
    # named `helper`. The veto asks the call's own `self` about the site's name too: `Box` answers `helper`, whatever
    # the node is.
    it "takes the method name from the site, not from the call node" do
      expect(statements[12].name).to eq(:send)
      expect(answer(:helper, statements[12]).describe).to eq('"top"')
      expect(answer(:twice, statements[9], args: [combinator.constant_of(4)]).describe).to eq("4")
      expect(answer(:helper, box[1].body.body[1])).to be_nil
    end

    it "takes the block type from the site" do
      seen = combinator.constant_of(:seen)

      expect(answer(:each_top, statements[11], block_type: seen)).to eq(seen)
      expect(answer(:each_top, statements[11]).describe).not_to eq(":seen")
    end

    # The body's `self` is the receiver the site holds: `def me = self`.
    it "takes the receiver from the site" do
      expect(answer(:me, statements[14]).describe).to eq("Object")
      expect(answer(:me, statements[14], receiver: combinator.nominal_of("Box")).describe).to eq("Box")
    end

    # A top-level `def` matched by name whose body cannot be re-typed shadows whatever the dispatcher would find.
    it "answers `Dynamic[top]` for a top-level def whose body it cannot re-type" do
      expect(answer(:twice, statements[10])).to eq(combinator.untyped)
    end

    it "answers nothing for an explicit receiver, or a name no top-level def has" do
      expect(answer(:helper, statements[13])).to be_nil
      expect(answer(:missing, statements[9])).to be_nil
    end

    # Issue #618 — the call's own `self` answers first: an instance method (`Box#helper`), a class method
    # (`Box.label`), a struct member (`Line#twice`). A name it does not answer still binds the top-level `def`.
    it "answers nothing where the call's own `self` answers the name" do
      probe = box[1].body.body
      build = box[3].body.body
      member = statements[6].value.block.body.body.first.body.body.first

      expect(answer(:helper, probe[0])).to be_nil
      expect(answer(:twice, probe[1], args: [combinator.constant_of(1)]).describe).to eq("1")
      expect(answer(:label, build[0])).to be_nil
      expect(answer(:helper, build[1]).describe).to eq('"top"')
      expect(answer(:twice, member, args: [combinator.constant_of(2)])).to be_nil
    end

    # Issue #963 item 2 — a member a plugin supplies is the call's own `self` answering too, asked by the site's name:
    # `Account#email` is synthetic, and the node is `other`.
    it "answers nothing where a plugin answers the site's name on the call's own `self`" do
      other = statements[8].body.body.first.body.body.first

      expect(other.name).to eq(:other)
      expect(answer(:email, other)).to be_nil
      expect(answer(:helper, other).describe).to eq('"top"')
    end

    # Issue #2861 — under an unmodelled `self` the #316 gate declines a top-level `def` from another file, and the
    # answer is `Dynamic[top]`, never the RBS method of the name. The `def` is looked up by the site's name: the node
    # here is `other`'s, which no top-level `def` has, and the site `email`'s.
    it "answers `Dynamic[top]` for the site's name where the #316 gate declines the bind" do
      key = Rigor::Inference::ScopeIndexer::TOP_LEVEL_DEF_KEY
      top = index.fetch(statements[9])
      away = top.with_discovery(top.discovery.with(discovered_def_sources: { key => { email: "/project/a.rb:12" } }))
                .with_source_path("/project/b.rb").entering_opaque_block
      other = statements[8].body.body.first.body.body.first

      expect(away.bindable_top_level_def_for(:email)).to be_nil
      expect(answer(:email, other, scope: away)).to eq(combinator.untyped)
      expect(answer(:helper, other, scope: away).describe).to eq('"top"')
      expect(answer(:missing, other, scope: away)).to be_nil
    end
  end

  it "exposes the rung alone, and hides the rest" do
    scope = index.fetch(statements[9])

    expect(described_class.singleton_class.public_instance_methods(false)).to contain_exactly(:try_call)
    expect { described_class.meta_member?("Line", :twice, scope) }.to raise_error(NoMethodError, /private/)
  end
end
