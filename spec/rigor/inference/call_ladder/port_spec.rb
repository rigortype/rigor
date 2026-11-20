# frozen_string_literal: true

require "spec_helper"

# ADR-116 WD12 — a rung module under `lib/rigor/inference/call_ladder/` is given the walking typer as its frame, and
# what it may do with it is `Rigor::Inference::CallLadder::PORT`.
#
# The rule. The reading ({CallLadderPort}, `spec/support/call_ladder_port.rb`) takes every use of the local `typer` in a
# rung module's file. Each must be one of:
#
# - the receiver of a call whose name is in `PORT`. `send`, `public_send`, `method`, `instance_variable_get` and any
#   other method are calls like the rest, and none is in the list;
# - a positional argument of a function of the same file whose parameter at that position is named `typer`;
# - a positional argument of another rung module's entry that is given the typer: its rung's own entry, or a
#   second entry whose row says `given_typer`.
#
# Anything else is the typer leaving the port: a local assigned from it, a collection holding it, a call that passes
# it to a constant that is no rung. A scope is read as `typer.scope` and off nothing else.
#
# Nor does the module type code another way: it names no typing class (`CallLadderPort::TYPING_CLASSES`:
# `ExpressionTyper`, `StatementEvaluator`), and calls no typing entry (`CallLadderPort::TYPING_ENTRIES`: the typer's
# `return_type_for`, and each method of `Scope` that builds a typer, which the spec reads off `scope.rb`) on anything
# but the local `typer`, `typer.scope` included. Either would type past `PORT` and the cut-off. It calls no `const_get`
# on anything (`CallLadderPort::CONSTANT_LOOKUPS`), whatever the argument: `Rigor::Inference.const_get(:ExpressionTyper)`
# names a typing class with no constant node to see, and a name the module builds could name any. A rung names the
# constants it uses.
#
# Beside that, the tables are held to the code from both sides. A rung module exposes exactly its rung's `asked_as`
# and the entries `CallLadder::SECOND_ENTRIES` names for it; every other function is hidden by `private_class_method`.
# The rung's entry takes `(site, typer)`. A second entry that is not given the typer is a function of its arguments
# alone: it takes neither a typer nor a scope, calls nothing with no receiver and nothing on `self` or on a constant,
# and reads no instance, class or global variable. Every member of `PORT` is called by some rung, no rung calls back
# more than four members beside `scope` (the #3318 cut-off), and each member is a public method of the typer. `PORT` is
# `scope`, the public callbacks (`CallLadder::PUBLIC_CALLBACKS`) and the re-entry points (`CallLadder::REENTRY`). A
# public callback (`type_of`) was public before any rung needed it: it counts toward the cut-off as a re-entry point
# does, and is exempt from the rest. `scope` and each re-entry point are marked `@api private`, and the re-entry points
# are made public by the typer's one `public` statement.
#
# Every name the reading matches comes from a table, so a rung slice edits `call_ladder.rb` and not this file. The
# examples under "the reading" prove the rule on a rung module and tables of their own.
#
# What the reading cannot see. It knows the typer by the name of the local that holds it, so a typer reached another
# way is not held: one a function builds, or one read off another object. A typer built for the module by another
# module it calls (`OperandWalk` builds one) is not seen either. It reads the files under `call_ladder/`
# only. A call spelled through `send` on something that is not the local `typer` is a call on that other thing. A
# typing class reached by a way that is neither a constant nor `const_get` (`eval`, `ObjectSpace`, a constant another
# module hands over) is not seen.
RSpec.describe "The call ladder's port" do
  def ladder = Rigor::Inference::CallLadder

  describe "of this checkout" do
    it_behaves_like "the port the tables declare"

    it "is frozen with the tables beside it, and read by nothing under lib/" do
      tables = [ladder::PORT, ladder::PUBLIC_CALLBACKS, ladder::REENTRY, ladder::SECOND_ENTRIES,
                ladder::DISPATCHER_INTERIOR]

      inside = CallLadderPin.table_reads("PORT.include?(name); SECOND_ENTRIES; PUBLIC_CALLBACKS", inside: true)

      expect(tables).to all(satisfy { |table| Ractor.shareable?(table) })
      expect(inside.size).to eq(3)
      expect(CallLadderPin.table_reads("CallLadder::REENTRY + CallLadder::DISPATCHER_INTERIOR").size).to eq(2)
      expect(CallLadderPin.engine_reads).to eq([])
    end

    # `CallLadderPort::TYPING_ENTRIES` is the port's list of what types code; a method `Scope` gains that builds a
    # typer has to join it, or a rung module could type through that method on `typer.scope`.
    it "knows each method of Scope that builds a typer as a typing entry" do
      builders = CallLadderPort.typer_builders(File.read(File.join(CallLadderPort::ROOT, CallLadderPort::SCOPE_FILE)))

      expect(builders).to include(:type_of, :user_method_return, :evaluate)
      expect(CallLadderPort::TYPING_ENTRIES).to include(*builders)
    end

    it "names each second entry once, at a rung module, with its reason" do
      entries = ladder::SECOND_ENTRIES
      homes = ladder::RUNGS.map(&:home).select { |home| home.start_with?(CallLadderPort::RUNG_HOME) }
      names = entries.map { |entry| [entry.home, entry.name] }

      expect(names).to eq(names.uniq)
      expect(entries.map(&:home) - homes).to eq([])
      expect(entries.map(&:because)).to all(match(/\S/))
      expect(entries.map(&:given_typer)).to all(be(true).or(be(false)))
    end
  end

  describe "the reading" do
    # A rung module in the shapes the real one has: the entry, a second entry that takes the typer, a gate that does
    # not, a function that only reads the scope, and one the typer is handed on to.
    let(:rung) do
      <<~RUBY
        module Rigor::Inference::CallLadder::Sample
          module_function

          def try_call(site, typer)
            infer(site.receiver, site.method_name, typer)
          end

          def infer(receiver, name, typer)
            return nil unless admits?(receiver)

            found = lookup(name, typer.scope)
            typer.infer_user_method_return(found, receiver, []) || fallback(name, typer)
          end

          def admits?(receiver)
            !receiver.class_name.nil?
          end

          def lookup(name, scope) = scope.user_def_for("C", name)

          def fallback(name, typer) = typer.degrade_if_overridable(nil, nil, name, :instance)

          private_class_method :lookup, :fallback
        end
      RUBY
    end
    let(:port) { %i[scope infer_user_method_return degrade_if_overridable] }
    let(:given) { { "CallLadder::Sample" => %i[try_call infer], "CallLadder::UserMethod" => %i[try_call infer] } }

    def read(source) = CallLadderPort::RungFile.new("CallLadder::Sample", source)
    def breaches(source) = read(source).typer_breaches(port, given)

    # `source` with `from` replaced by `to`; text that is not there exactly once raises.
    def edit(source, from, to)
      found = source.scan(from).size
      raise ArgumentError, "#{from.inspect} occurs #{found} times, not once" unless found == 1

      source.sub(from) { to }
    end

    it "takes what the module calls on its typer and what it exposes, and finds nothing wrong with either" do
      file = read(rung)

      expect(file.typer_calls).to eq(%i[scope infer_user_method_return degrade_if_overridable])
      expect(file.entries).to eq(%i[try_call infer admits?])
      expect(file.parameters(:try_call)).to eq(%i[site typer])
      expect(file.method_count).to eq(5)
      expect(breaches(rung) + file.foreign_scope_reads + file.impurities(:admits?)).to eq([])
    end

    it "fails a call on the typer that the port does not list, `send` and the other reflective calls included" do
      calls = %w[tracer send(:scope) public_send(:scope) method(:scope).call instance_variable_get(:@scope)]
      found = calls.map { |call| breaches(edit(rung, "typer.scope", "typer.#{call}")) }

      expect(found.map(&:size)).to eq([1, 1, 1, 1, 1])
      expect(found.flatten).to all(include("which is not in CallLadder::PORT"))
      expect(found.first.first).to eq("CallLadder::Sample.infer (line 11): calls `typer.tracer`, which is not in " \
                                      "CallLadder::PORT")
      expect(breaches(rung)).to eq([])
    end

    it "fails a typer that leaves the port: a local, a collection, a function that takes it under another name" do
      aliased = edit(rung, "found = lookup(name, typer.scope)", "frame = typer\n    found = lookup(name, frame.scope)")
      held = edit(rung, "fallback(name, typer)\n", "fallback(name, [typer].first)\n")
      renamed = edit(rung, "def fallback(name, typer) = typer.degrade", "def fallback(name, frame) = frame.degrade")
      misplaced = edit(rung, "fallback(name, typer)\n", "fallback(typer, name)\n")
      outside = edit(rung, "fallback(name, typer)\n", "Fallback.record(name, typer)\n")

      expect([aliased, held, renamed, misplaced, outside].map { |source| breaches(source).size }).to eq([1, 1, 1, 1, 1])
      expect(breaches(aliased).first).to include("the typer leaves the port (used as local_variable_write_node)")
      expect(breaches(outside).first).to include("an argument of `Fallback.record`")
    end

    it "lets the typer go to another rung's entry that is given one, under any written path, and to no other" do
      entry = edit(rung, "fallback(name, typer)\n", "UserMethod.infer(receiver, nil, [], name, nil, typer)\n")
      full = edit(rung, "fallback(name, typer)\n", "::Rigor::Inference::CallLadder::UserMethod.try_call(site, typer)\n")
      gate = edit(rung, "fallback(name, typer)\n", "UserMethod.user_inference_receiver?(typer)\n")
      other = edit(rung, "fallback(name, typer)\n", "Other::UserMethod.infer(receiver, typer)\n")

      expect([entry, full].map { |source| breaches(source) }).to eq([[], []])
      expect([gate, other].map { |source| breaches(source).size }).to eq([1, 1])
    end

    # ADR-116, the #3318 cut-off: a public callback is a fifth callback as a re-entry point would be.
    it "counts a public callback toward the cut-off as it counts a re-entry point, and the scope read as neither" do
      typed = edit(rung, "found = lookup(name, typer.scope)", "found = lookup(typer.type_of(name), typer.scope)")
      reentry = %i[infer_user_method_return degrade_if_overridable]

      expect(CallLadderPort.callbacks(read(rung).typer_calls)).to eq(reentry)
      expect(CallLadderPort.callbacks(read(typed).typer_calls)).to eq([:type_of, *reentry])
    end

    it "fails a scope read off anything but the typer" do
      source = edit(rung, "lookup(name, typer.scope)", "lookup(name, site.scope)")

      expect(read(source).foreign_scope_reads).to eq(
        ["CallLadder::Sample.infer (line 11): reads `site.scope`; a rung reads the scope as `typer.scope`"]
      )
    end

    # The probe #3371's review wrote: `PORT` holds what the module calls on its typer, and neither call below is one.
    it "fails a rung that types past its typer: a typing class named, a typing entry called on a scope" do
      probe = edit(rung, "found = lookup(name, typer.scope)",
                   "found = typer.scope.type_of(receiver) || " \
                   "Rigor::Inference::ExpressionTyper.new(scope: typer.scope).send(:dynamic_top)")

      expect(breaches(probe) + read(probe).foreign_scope_reads).to eq([])
      expect(read(probe).typing_bypasses).to eq(
        ["CallLadder::Sample.infer (line 11): names `Rigor::Inference::ExpressionTyper`; a rung types only through " \
         "its typer",
         "CallLadder::Sample.infer (line 11): calls `type_of` on `typer.scope`; a rung types only through its typer"]
      )
    end

    it "fails every typing entry on a scope, under any spelling, and every typing class, and passes the rest" do
      lookup = "scope.user_def_for(\"C\", name)"
      spelled = [
        "scope.send(:evaluate, name)", "[scope].map(&:user_method_return)", "scope.return_type_for(name, nil, [])",
        "type_of(name)", "StatementEvaluator.new(scope: scope)", "ExpressionTyper::Writes"
      ]
      bypasses = ->(to) { read(edit(rung, lookup, to)).typing_bypasses }

      expect(spelled.map { |to| bypasses.call(to).size }).to eq([1, 1, 1, 1, 1, 1])
      expect(read(rung).typing_bypasses).to eq([])
      expect(bypasses.call("Type::Nominal.new(scope.user_def_for(name))")).to eq([])
    end

    # The two probes #3371's second review round wrote: each names `ExpressionTyper` with no constant node for it.
    it "fails `const_get` on anything, whatever it names and however it is spelled" do
      lookup = "scope.user_def_for(\"C\", name)"
      probes = [
        "Rigor::Inference.const_get(:ExpressionTyper).new(scope: scope)",
        "Object.const_get(\"Rigor::Inference::ExpressionTyper\").new(scope: scope)"
      ]
      spelled = ["Type.const_get(name)", "Object.send(:const_get, name)", "[name].map(&Object.method(:const_get))",
                 "[Type].map(&:const_get)"]
      bypasses = ->(to) { read(edit(rung, lookup, to)).typing_bypasses }

      expect(bypasses.call(probes.first)).to eq(
        ["CallLadder::Sample.lookup (line 19): calls `const_get`; a rung names the constants it uses, and types only " \
         "through its typer"]
      )
      expect((probes + spelled).map { |to| bypasses.call(to).size }).to eq([1, 1, 1, 1, 1, 1])
      expect(bypasses.call("Type.const_defined?(name) && Type::Nominal")).to eq([])
    end

    it "reads what a module exposes off its `private_class_method`, and a name it hides with no definition" do
      opened = edit(rung, "private_class_method :lookup, :fallback", "private_class_method :fallback")
      stale = edit(rung, "private_class_method :lookup, :fallback", "private_class_method :lookup, :fallback, :gone")

      expect(read(opened).entries).to eq(%i[try_call infer admits? lookup])
      expect(read(stale).hidden_without_def).to eq(%i[gone])
      expect(read(rung).hidden_without_def).to eq([])
    end

    it "takes the entries the tables give a module, and which of them are given the typer" do
      rungs = [ladder::Rung.new(name: :sample, asked_by: %i[call], home: "CallLadder::Sample", asked_as: %i[try_call],
                                in_typer_because: nil)]
      second = [
        ladder::SecondEntry.new(home: "CallLadder::Sample", name: :infer, given_typer: true, because: "positionals"),
        ladder::SecondEntry.new(home: "CallLadder::Sample", name: :admits?, given_typer: false, because: "the gate"),
        ladder::SecondEntry.new(home: "CallLadder::Other", name: :ask, given_typer: true, because: "another rung")
      ]
      tables = { rungs: rungs, second_entries: second }

      expect(CallLadderPort.declared_entries("CallLadder::Sample", **tables)).to eq(read(rung).entries)
      expect(CallLadderPort.typer_entries("CallLadder::Sample", **tables)).to eq(%i[try_call infer])
    end

    describe "of an entry that is not given the typer" do
      def impurities(from, to) = read(edit(rung, from, to)).impurities(:admits?)

      it "fails one that takes a typer or a scope, by any kind of parameter" do
        expect(impurities("def admits?(receiver)", "def admits?(receiver, typer)"))
          .to eq(["CallLadder::Sample.admits? takes `typer`"])
        expect(impurities("def admits?(receiver)", "def admits?(receiver, scope: nil)"))
          .to eq(["CallLadder::Sample.admits? takes `scope`"])
      end

      it "fails a call with no receiver: a function of the module, or a typer or scope it was not given" do
        body = "!receiver.class_name.nil?"

        expect(impurities(body, "#{body} && lookup(receiver, nil)"))
          .to eq(["CallLadder::Sample.admits? calls `lookup` with no receiver"])
        expect(impurities(body, "#{body} && typer.scope.known?(receiver)"))
          .to eq(["CallLadder::Sample.admits? calls `typer` with no receiver"])
        expect(impurities(body, "#{body} && scope.known?(receiver)"))
          .to eq(["CallLadder::Sample.admits? calls `scope` with no receiver"])
      end

      it "fails a call on a constant or on `self`, and a read of a variable that is not a local" do
        body = "!receiver.class_name.nil?"

        expect(impurities(body, "#{body} && ExpressionTyper.current_forwarded_arg_types.nil?"))
          .to eq(["CallLadder::Sample.admits? calls `ExpressionTyper.current_forwarded_arg_types`"])
        expect(impurities(body, "#{body} && self.lookup(receiver, nil)"))
          .to eq(["CallLadder::Sample.admits? calls `self.lookup`"])
        expect(impurities(body, "#{body} && @seen && $all")).to eq(
          ["CallLadder::Sample.admits? reads `@seen`", "CallLadder::Sample.admits? reads `$all`"]
        )
      end

      it "passes one that tests constants and calls only on its arguments" do
        tested = "case receiver\n    when Type::Nominal then true\n    else !receiver.class_name.nil?\n    end"

        expect(impurities("!receiver.class_name.nil?", tested)).to eq([])
        expect(read(rung).impurities(:infer)).to include("CallLadder::Sample.infer takes `typer`")
        expect(read(rung).impurities(:gone)).to eq(["CallLadder::Sample.gone has no single definition"])
      end
    end

    describe "of the typer's side" do
      let(:typer) do
        <<~RUBY
          class ExpressionTyper
            # @api private — the frame's scope.
            attr_reader :scope

            private

            attr_reader :tracer

            # @api private — a member of the port.
            #
            # What it does.
            def infer_user_method_return(def_node) = def_node

            # No mark here.
            def degrade_if_overridable(result) = result

            def unmarked = nil

            public :infer_user_method_return, :degrade_if_overridable
          end
        RUBY
      end

      it "reads the comment directly above a definition, of a `def` or of the `attr_reader` that names it" do
        expect(CallLadderPort.comment_above(typer, :scope)).to include("@api private")
        expect(CallLadderPort.comment_above(typer, :infer_user_method_return)).to include("@api private", "What it")
        expect(CallLadderPort.comment_above(typer, :degrade_if_overridable)).to eq("  # No mark here.\n")
        expect(CallLadderPort.comment_above(typer, :tracer)).to eq("")
        expect(CallLadderPort.comment_above(typer, :unmarked)).to eq("")
        expect(CallLadderPort.comment_above(typer, :gone)).to be_nil
      end

      it "reads the names a `public` statement lists, in its order" do
        expect(CallLadderPort.made_public(typer)).to eq(%i[infer_user_method_return degrade_if_overridable])
        expect(CallLadderPort.made_public("public\ndef a; end\npublic def b; end\nother.public :c")).to eq([])
      end
    end
  end
end
