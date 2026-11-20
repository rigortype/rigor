# frozen_string_literal: true

require "spec_helper"

# ADR-116 WD12 — who may call the typer's re-entry points, and who may ask the dispatcher's interior.
#
# A re-entry point (`Rigor::Inference::CallLadder::REENTRY`) is a method of `ExpressionTyper` that is public only so
# that a rung module can call it on the typer it is given. It runs the typer's own code: the cursor `@typing_node` is
# the node the walking `type_of` is on, and the frames `TypingState` pushes around a body are the ones that walk
# pushed. Both are right only inside the `type_of` walk that asked the rung, so being public does not make one
# callable from a typer some other code holds. The rule, read with Prism over the engine, the plugins and the
# examples ({CallLadderPort}, `spec/support/call_ladder_port.rb`):
#
# - in `expression_typer.rb` a re-entry point is called with no receiver or on `self`;
# - in a file under `call_ladder/` it is called on the local `typer`;
# - no other file reaches one, and none is reached through a reflective call that spells its name (`send`,
#   `public_send`, `method`, …) or as a `&:name` block.
#
# The names are held as names: a method of that name on any other object fails here too. `scope`, the port's other
# member, is not a re-entry point and is not held; it reads the frame and runs nothing.
#
# The second rule is about the other direction. `CallLadder::DISPATCHER_INTERIOR` (`resolve`, `resolve_site`) is the
# dispatcher's own: `resolve_site` is the tier ladder and `resolve` its keyword entry for a tier that dispatches
# again. Neither makes the records `dispatch_site` makes after an answer. The typer, its modules and the rung
# modules ask the dispatcher by its row's `asked_as` and never by one of these.
#
# What the reading cannot see: a name built at run time, a `Method` object taken elsewhere and called here, and a
# file outside the three trees it reads (`spec/`, `tool/`).
RSpec.describe "The typer's re-entry points" do
  describe "of this checkout" do
    it_behaves_like "the re-entry points the tables declare"
  end

  describe "the reading" do
    let(:typer_file) { CallLadderPort::TYPER_FILE }
    let(:rung_file) { "#{CallLadderPort::RUNG_DIRECTORY}user_method.rb" }
    let(:reentry) { %i[infer_user_method_return class_graph_buckets] }

    # `body` as the body of a function that holds a typer, a site and a list, as a rung's functions do.
    def breaches(path, body)
      source = "def f(typer, site, typers)\n  #{body}\nend\n"
      CallLadderPort.reentry_breaches({ path => source }, reentry: reentry)
    end

    it "passes the typer's own calls and a rung module's call on its typer" do
      own = "infer_user_method_return(d, r, a); self.class_graph_buckets[:x]; public :infer_user_method_return"
      rung = "typer.infer_user_method_return(d, r, a, yield_type: b); typer.class_graph_buckets[:typing_def]"

      expect(breaches(typer_file, own)).to eq([])
      expect(breaches(rung_file, rung)).to eq([])
    end

    it "fails a call from any other file, with a receiver or with none" do
      expect(breaches("lib/rigor/inference/statement_evaluator.rb", "typer.infer_user_method_return(d, r, a)")).to eq(
        ["lib/rigor/inference/statement_evaluator.rb: `typer.infer_user_method_return` reaches the typer's re-entry " \
         "point `infer_user_method_return` outside a rung module's call on its typer"]
      )
      expect(breaches("plugins/rigor-x/lib/rigor/x.rb", "class_graph_buckets").size).to eq(1)
      expect(breaches("lib/rigor/inference/expression_typer/writes.rb", "typer.class_graph_buckets").size).to eq(1)
      expect(breaches("lib/rigor/scope.rb", "class_graph; buckets; infer_user_method_returns")).to eq([])
    end

    it "fails a call on another typer from inside the typer, and on anything but `typer` from inside a rung" do
      expect(breaches(typer_file, "typer_under(other).infer_user_method_return(d, r, a)")).to eq(
        ["#{typer_file}: `typer_under(other).infer_user_method_return` reaches `infer_user_method_return` on " \
         "something other than the typer itself"]
      )
      expect(breaches(rung_file, "site.class_graph_buckets").size).to eq(1)
      expect(breaches(rung_file, "class_graph_buckets").size).to eq(1)
    end

    it "fails a reflective call that spells the name, and a `&:name` block, wherever they stand" do
      spelled = [
        "typer.send(:infer_user_method_return, d)", "typer.public_send('class_graph_buckets')",
        "typer.method(:class_graph_buckets)", "typers.map(&:class_graph_buckets)", "send(:infer_user_method_return, d)"
      ]

      expect(spelled.map { |source| breaches(rung_file, source).size }).to eq([1, 1, 1, 1, 1])
      expect(spelled.map { |source| breaches(typer_file, source).size }).to eq([1, 1, 1, 1, 1])
      expect(breaches(typer_file, "send(handler, node); typer.send(:scope); names.map(&:to_s)")).to eq([])
    end

    it "finds the dispatcher's interior asked on the dispatcher, under any written path, and not another `resolve`" do
      asked = <<~RUBY
        MethodDispatcher.resolve(receiver_type: r, method_name: :x, arg_types: [])
        ::Rigor::Inference::MethodDispatcher.resolve_site(site)
        MethodDispatcher.send(:resolve_site, site)
        MethodDispatcher.dispatch_site(site); MethodDispatcher.dispatch(receiver_type: r, method_name: :x, arg_types: [])
        DefinerResolution.resolve(scope, name, :x, :instance, question: :definer); resolve(x); context.resolve_site
      RUBY

      expect(CallLadderPort.interior_calls(asked)).to eq(
        %w[MethodDispatcher.resolve ::Rigor::Inference::MethodDispatcher.resolve_site MethodDispatcher.send]
      )
    end
  end
end
