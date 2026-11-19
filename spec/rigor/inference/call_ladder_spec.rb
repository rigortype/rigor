# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# ADR-116 WD12 — the order `ExpressionTyper` types a call in is the one `Rigor::Inference::CallLadder` declares.
#
# The rule. A *place* is where the code writes a sequence of rungs: the methods an entry of `CallLadder::ENTRIES`
# names (`call`, `index_read`, `send_target`), and the branch an exception row names (a splat index read). The
# reading ({CallLadderPin}, `spec/support/call_ladder_pin.rb`) takes everything a place's methods can answer
# with: the argument of a `return` and the last expression, through `||` and through the locals they read. In
# order, that must be
#
# - what the entry lets answer ahead of its ladder (`ahead`), and then
# - the rungs whose rows name the entry, in the rows' order, less the ones an exception row omits; a rung an
#   exception row gates is asked through its gate.
#
# So a rung out of order, a rung left out, a rung its row does not give the entry and a call that has no row
# each fail, and so does an exception row that goes while the code it excuses stays. Two more hold the rest of
# the files read to the tables: a place's method asks a rung only where it answers with it, and no other method
# asks the ladder for two or more different things, a rung or a method a place is written in. A method that asks
# for one is not an order and is not held. A failure says which edit settles it ({CallLadderPin::Advice}).
#
# Every spelling the reading matches comes from a row. The examples under "the reading" prove that on a small
# typer and tables of their own, so that a rung whose body moves edits its row in `call_ladder.rb` and nothing
# here: the dispatcher under either of its entries, a rung asked on its module, a sequence written in one.
#
# What the reading cannot see. In what a place answers with, every call has to be declared, so a rung asked there
# through `send`, a `Method` object or a local alias of its module fails as a call with no row. The two checks on
# the rest of the files know a rung by its spelling alone and miss one asked that way: where a method does not
# answer with it, and as the second rung of a method outside the places. The files read are the typer, the
# modules under `expression_typer/` and the rung modules under `call_ladder/`; a sequence written anywhere else
# is not read at all. A place written in a shape the reading does not follow (`&&`, `case`, `rescue`, a multiple
# assignment) fails as unreadable; it does not pass.
#
# Two parts of the reader have no example, because taking either out only makes the reading stricter: answers
# are listed once each (`uniq`), where a local returned from two places would otherwise repeat its call and fail
# the comparison, and a `return` inside a lambda is not read, where reading it would add an answer to declare.
RSpec.describe Rigor::Inference::CallLadder do
  def ladder = described_class
  def rung(name) = ladder::RUNGS.find { |row| row.name == name }

  describe "the tables" do
    it "name each rung once and give it the entries that ask it, in the entries' order" do
      names = ladder::RUNGS.map(&:name)
      entries = ladder::ENTRIES.map(&:name)

      expect(entries).to eq(%i[call index_read send_target])
      expect(names).to eq(names.uniq)
      expect(ladder::RUNGS.map(&:asked_by)).to all(satisfy { |asked| asked.any? && asked == entries & asked })
    end

    it "hold the dispatcher as one row every entry asks, and a call as the entry that asks every rung" do
      expect(rung(:dispatcher).asked_by).to eq(ladder::ENTRIES.map(&:name))
      expect(ladder::RUNGS.map(&:asked_by)).to all(include(:call))
    end

    it "say why each rung whose body is a typer method is still one, and nothing for any other rung" do
      in_typer, elsewhere = ladder::RUNGS.partition { |row| row.home == "ExpressionTyper" }

      expect(in_typer.map(&:in_typer_because)).to all(match(/\A(?:S\d moves it|stays: )/))
      expect(elsewhere.map(&:name)).to include(:dispatcher)
      expect(elsewhere.map(&:in_typer_because)).to all(be_nil)
    end

    # Drift is a defect: its row names the issue whose fix deletes it, and a newly found one needs no more than
    # that. A row with no issue is a design, and ADR-116 names the one there is.
    it "except by drift recorded against an issue, or by the one design ADR-116 names" do
      drift, design = ladder::EXCEPTIONS.partition(&:issue)

      expect(design.map(&:name) - %i[splat_index_read]).to eq([])
      expect(drift.map(&:issue)).to all(be_an(Integer).and(be_positive))
    end

    it "except only rungs the row's entry asks, each row with something excepted and its reason" do
      ladder::EXCEPTIONS.each do |row|
        asked = ladder::RUNGS.select { |candidate| candidate.asked_by.include?(row.entry) }.map(&:name)
        excepted = row.omits + row.gates.map(&:rung)

        expect(excepted).not_to be_empty
        expect(asked).to include(*excepted)
        expect(row.because).to match(/\S/)
      end
    end

    it "are frozen all the way down" do
      tables = [ladder::ENTRIES, ladder::RUNGS, ladder::EXCEPTIONS]

      expect(tables).to all(satisfy { |table| Ractor.shareable?(table) })
    end

    # ADR-116 rejects a ladder walked at run time, so the tables are for this spec and for a reader. The scan is
    # proved on a source that does read them, then run over `lib/`.
    it "are read by nothing under lib/: no file requires them or names one" do
      reads = <<~RUBY
        require_relative "call_ladder"
        require "rigor/inference/call_ladder"
        order = Rigor::Inference::CallLadder::RUNGS.map(&:name) + CallLadder::ENTRIES + RUNGS
      RUBY

      others = 'require_relative "call_ladder/user_method"; ENTRIES; Other::RUNGS_OF; "RUNGS"'

      expect(CallLadderPin.table_reads(reads).size).to eq(5)
      expect(CallLadderPin.table_reads("EXCEPTIONS.first; ENTRIES", inside: true).size).to eq(2)
      expect(CallLadderPin.table_reads(others)).to eq([])
      expect(CallLadderPin.engine_reads).to eq([])
    end
  end

  describe "the typer's code" do
    it_behaves_like "the call ladder the tables declare"
  end

  describe "the reading" do
    # The typer's five ladder methods in the shapes it writes them in, the dispatcher's wrapper, and one rung's
    # own body, which tests its gate and asks another rung once.
    let(:typer) do
      <<~RUBY
        class ExpressionTyper
          def call_result_type_for(node)
            narrowed = indexed_narrowing_for(node)
            return narrowed if narrowed

            refined = try_refined_dispatch(node)
            return refined if refined

            literal_send = try_literal_send(node)
            return literal_send if literal_send

            local_def = try_local_def_dispatch(node)
            return local_def if local_def

            block_fold = try_receiver_block_folds(node)
            return block_fold if block_fold

            overriding_def = try_overriding_def_dispatch(node)
            return overriding_def if overriding_def

            result = MethodDispatcher.dispatch(node)
            return result if result

            dispatch_miss_result(node)
          end

          def dispatch_miss_result(node)
            user = try_user_method_inference(node)
            return user if user

            singleton = try_project_singleton_inference(node)
            return singleton if singleton

            return inherit_receiver_origin(node) if node.dynamic?

            retried = try_non_nil_receiver_retry(node)
            return retried if retried

            unresolved_call_result(node)
          end

          def implicit_index_read_type(node)
            return splat_index_read_type(node) if splat_arguments?(node)

            try_overriding_def_dispatch(node) || index_read_dispatch(node) ||
              try_user_method_inference(node) || try_project_singleton_inference(node)
          end

          def splat_index_read_type(node)
            return dynamic_top if overriding_own_def?(node)

            index_read_dispatch(node)
          end

          def index_read_dispatch(node)
            MethodDispatcher.dispatch(node, :[])
          end

          def try_literal_send(node)
            args = literal_send_arguments(node)
            return nil if args.nil?
            return own_send_type(node) if node.name == :send

            MethodDispatcher.dispatch(args) || try_user_method_inference(args) ||
              try_project_singleton_inference(args)
          end

          def try_overriding_def_dispatch(node)
            return nil unless overriding_own_def?(node)

            try_user_method_inference(node) || dynamic_top
          end
        end
      RUBY
    end

    # Tables of the shape `CallLadder`'s had when every rung but the dispatcher was a typer method.
    let(:rungs) do
      every = %i[call index_read send_target]
      [
        row(:refined, :try_refined_dispatch, %i[call index_read]),
        row(:literal_send, :try_literal_send, %i[call]),
        row(:top_level_def, :try_local_def_dispatch, %i[call]),
        row(:receiver_block_folds, :try_receiver_block_folds, %i[call]),
        row(:overriding_def, :try_overriding_def_dispatch, %i[call index_read]),
        row(:dispatcher, %i[dispatch dispatch_site], every, home: "MethodDispatcher"),
        row(:user_method, :try_user_method_inference, every),
        row(:project_singleton, :try_project_singleton_inference, every),
        row(:dynamic_receiver, :inherit_receiver_origin, %i[call]),
        row(:non_nil_retry, :try_non_nil_receiver_retry, %i[call]),
        row(:unresolved, :unresolved_call_result, %i[call])
      ]
    end
    let(:entries) do
      { call: [%i[call_result_type_for dispatch_miss_result], %i[indexed_narrowing_for]],
        index_read: [%i[implicit_index_read_type], []],
        send_target: [%i[try_literal_send], %i[own_send_type]] }.map do |name, (written_in, ahead)|
        ladder::Entry.new(name: name, home: "ExpressionTyper", written_in: written_in, ahead: ahead)
      end
    end
    let(:exceptions) do
      gate = ladder::Gate.new(rung: :overriding_def, ask: :overriding_own_def?, answer: :dynamic_top)
      [
        ladder::ExceptionRow.new(name: :index_read_without_refined, entry: :index_read, written_in: nil,
                                 omits: %i[refined], gates: [], issue: 3358, because: "drift"),
        ladder::ExceptionRow.new(name: :splat_index_read, entry: :index_read, written_in: :splat_index_read_type,
                                 omits: %i[user_method project_singleton], gates: [gate], issue: nil,
                                 because: "no arguments")
      ]
    end

    def row(name, asked_as, asked_by, home: "ExpressionTyper")
      ladder::Rung.new(name: name, asked_by: asked_by, home: home, asked_as: Array(asked_as), in_typer_because: nil)
    end

    # The reading of `source` as the typer, under this group's tables or the ones given, beside any rung module
    # given as `modules`.
    def read(source, modules: {}, **tables)
      CallLadderPin::Reading.new(entries: entries, rungs: rungs, exceptions: exceptions,
                                 sources: { "ExpressionTyper" => source, **modules }, **tables)
    end

    def written(reading) = reading.places.to_h { |place| [place.name, reading.written(place)] }
    def expected(reading) = reading.places.to_h { |place| [place.name, reading.expected(place)] }

    # What each place asks, by name alone.
    def asked(source, **tables) = written(read(source, **tables)).transform_values { |sequence| sequence.map(&:last) }

    # The places of `source` whose code and tables disagree.
    def failing(source, **tables)
      reading = read(source, **tables)
      written(reading).reject { |place, sequence| sequence == expected(reading).fetch(place) }.keys
    end

    # `source` with `from` replaced by `to`. Text that is not there exactly `times` times raises, so an example
    # cannot pass on an edit that changed nothing.
    def edit(source, from, to, times: 1)
      found = source.scan(from).size
      raise ArgumentError, "#{from.inspect} occurs #{found} times, not #{times}" unless found == times

      source.gsub(from) { to }
    end

    def swap(source, first, second) = edit(edit(edit(source, first, "\0"), second, first), "\0", second)

    # A table with one row changed.
    def rows(table, name, **changes) = table.map { |row| row.name == name ? row.with(**changes) : row }

    it "takes the four sequences off the typer's shapes, and finds nothing hidden or astray" do
      reading = read(typer)

      expect(written(reading)).to eq(expected(reading))
      expect(asked(typer)).to include(
        index_read: %i[overriding_def dispatcher user_method project_singleton],
        splat_index_read: %i[overriding_def dispatcher],
        send_target: %i[own_send_type dispatcher user_method project_singleton]
      )
      expect(asked(typer)[:call].size).to eq(12)
      expect(reading.hidden_asks).to eq([])
      expect(reading.stray_sequences).to eq([])
    end

    it "follows the code's order through a statement ladder and into the method it continues in" do
      swapped = swap(typer, "= try_refined_dispatch(node)", "= try_literal_send(node)")
      early = edit(typer, "result = MethodDispatcher.dispatch(node)", "result = dispatch_miss_result(node)")
      early = edit(early, "\n    dispatch_miss_result(node)\n", "\n    MethodDispatcher.dispatch(node)\n")

      expect(asked(swapped)[:call].first(3)).to eq(%i[indexed_narrowing_for literal_send refined])
      expect(asked(early)[:call].last(4)).to eq(%i[dynamic_receiver non_nil_retry unresolved dispatcher])
      expect([failing(swapped), failing(early)]).to eq([[:call], [:call]])
    end

    it "follows it through a `||` chain and into a branch" do
      index_read = swap(typer, "try_overriding_def_dispatch(node) ||", "index_read_dispatch(node) ||")
      send_target = swap(typer, "try_user_method_inference(args)", "try_project_singleton_inference(args)")
      splat = edit(typer, "return dynamic_top if overriding_own_def?(node)", "found = index_read_dispatch(node)")
      splat = edit(splat, "\n    index_read_dispatch(node)\n",
                   "\n    found || (dynamic_top if overriding_own_def?(node))\n")

      expect(asked(index_read)[:index_read].first(2)).to eq(%i[dispatcher overriding_def])
      expect(asked(send_target)[:send_target].last(2)).to eq(%i[project_singleton user_method])
      expect(asked(splat)[:splat_index_read]).to eq(%i[dispatcher overriding_def])
      expect([index_read, send_target, splat].map { |source| failing(source) })
        .to eq([[:index_read], [:send_target], [:splat_index_read]])
    end

    it "shows a rung a place leaves out, and one its row does not give the place's entry" do
      dropped = edit(typer, " || try_user_method_inference(args)", "")
      added = edit(typer, "    try_overriding_def_dispatch(node) ||", "    try_local_def_dispatch(node) ||")

      expect(asked(dropped)[:send_target]).to eq(%i[own_send_type dispatcher project_singleton])
      expect(asked(added)[:index_read].first).to eq(:top_level_def)
      expect([failing(dropped), failing(added)]).to eq([[:send_target], [:index_read]])
    end

    it "shows a call with no row in what a place answers with: a rung is declared before it is asked" do
      shortcut = "    plugin = try_plugin_shortcut(node)\n    return plugin if plugin\n\n"
      source = edit(typer, "    refined = try_refined_dispatch", "#{shortcut}    refined = try_refined_dispatch")

      expect(written(read(source))[:call][1]).to eq([:undeclared, "try_plugin_shortcut"])
      expect(written(read(typer))[:call][1]).to eq(%i[rung refined])
      expect(failing(source)).to eq([:call])
    end

    it "shows rungs asked in one order and answered from in another" do
      source = swap(typer, "return refined if refined", "return literal_send if literal_send")

      expect(written(read(source))[:call].first.first).to eq(:order)
      expect(written(read(typer))[:call].map(&:first)).not_to include(:order)
      expect(failing(source)).to eq([:call])
    end

    it "shows an answer in a shape it does not follow, and a branch its entry no longer returns through" do
      shaped = edit(typer, "    unresolved_call_result(node)",
                    "    case node\n    when nil then unresolved_call_result(node)\n    end")
      unentered = edit(typer, "    return splat_index_read_type(node) if splat_arguments?(node)\n\n", "")

      expect(written(read(shaped))[:call].last).to match([:unreadable, /\Acase_node at line \d+\z/])
      expect(written(read(unentered))[:splat_index_read].map(&:first)).to eq([:missing])
      expect([failing(shaped), failing(unentered)]).to eq([[:call], [:splat_index_read]])
    end

    it "finds a rung asked where the method does not answer with it" do
      source = edit(typer, "    retried = try_non_nil_receiver_retry",
                    "    note(try_user_method_inference(node)) if node\n    retried = try_non_nil_receiver_retry")

      expect(read(source).hidden_asks).to eq([["ExpressionTyper", :dispatch_miss_result, :user_method]])
      expect(failing(source)).to eq([])
    end

    it "finds a second sequence in another method, and not a method that asks one rung, however often" do
      astray = "  def elsewhere(node)\n    index_read_dispatch(node) || try_user_method_inference(node)\n  end\n"
      single = "  def twice(node)\n    try_user_method_inference(node) || try_user_method_inference(nil)\n  end\n"
      source = edit(typer, /^end\n\z/, "#{astray}#{single}end\n")

      expect(read(source).stray_sequences).to eq([["ExpressionTyper", :elsewhere, %i[dispatcher user_method]]])
    end

    it "counts a method a place is written in as something asked of the ladder: a rung and a continuation astray" do
      fifth = "  def fifth(node)\n    try_overriding_def_dispatch(node) || dispatch_miss_result(node)\n  end\n"
      again = "  def again(node)\n    call_result_type_for(node) || call_result_type_for(nil)\n  end\n"
      source = edit(typer, /^end\n\z/, "#{fifth}#{again}end\n")

      expect(read(source).stray_sequences)
        .to eq([["ExpressionTyper", :fifth, %i[overriding_def dispatch_miss_result]]])
    end

    describe "of the dispatcher" do
      it "reads either of its entries, under any written path, and through a method that only wraps one" do
        site = edit(typer, "result = MethodDispatcher.dispatch(node)",
                    "result = ::Rigor::Inference::MethodDispatcher.dispatch_site(site)")
        wrapped = edit(typer, "    MethodDispatcher.dispatch(node, :[])", "    Inference::MethodDispatcher.dispatch_site(site)")
        inline = edit(typer, " index_read_dispatch(node) ||", " MethodDispatcher.dispatch_site(site) ||")
        inline = edit(inline, "    index_read_dispatch(node)\n  end", "    MethodDispatcher.dispatch_site(site)\n  end")

        expect([site, wrapped, inline].map { |source| failing(source) }).to eq([[], [], []])
        expect(asked(inline)[:splat_index_read]).to eq(%i[overriding_def dispatcher])
      end

      it "reads neither another constant's method of that name nor a wrapper that does more than wrap" do
        other = edit(typer, "result = MethodDispatcher.dispatch(node)", "result = Type::Dispatcher.dispatch(node)")
        wider = edit(typer, "    MethodDispatcher.dispatch(node, :[])",
                     "    note(node)\n    MethodDispatcher.dispatch(node)")

        expect(written(read(other))[:call][6]).to eq([:undeclared, "Type::Dispatcher.dispatch"])
        expect(written(read(wider))[:index_read][1]).to eq([:undeclared, "index_read_dispatch"])
        expect([failing(other), failing(wider)]).to eq([[:call], %i[index_read splat_index_read]])
      end
    end

    describe "of a rung whose body has moved" do
      let(:moved_rungs) { rows(rungs, :user_method, home: "CallLadder::UserMethod", asked_as: %i[try_call]) }
      let(:moved_typer) do
        calls = edit(typer, "try_user_method_inference(node)", "CallLadder::UserMethod.try_call(site, self)", times: 3)
        edit(calls, "try_user_method_inference(args)", "CallLadder::UserMethod.try_call(target, self)")
      end

      it "takes the new spelling from the row, which is all the move changes here" do
        reading = read(moved_typer, rungs: moved_rungs)

        expect(written(reading)).to eq(expected(reading))
        expect(reading.stray_sequences).to eq([])
      end

      it "holds the code to the row from both sides: the old call under the new row, the new call under the old" do
        places = %i[call index_read send_target]

        expect(failing(typer, rungs: moved_rungs)).to eq(places)
        expect(failing(moved_typer)).to eq(places)
        expect(written(read(moved_typer))[:send_target][2]).to eq([:undeclared, "CallLadder::UserMethod.try_call"])
      end

      it "reads a gate at its rung's home, and its answer only under that test" do
        moved_rungs = rows(rungs, :overriding_def, home: "CallLadder::OverridingDef", asked_as: %i[try_call])
        gated = edit(typer, "dynamic_top if overriding_own_def?(node)\n\n",
                     "dynamic_top if CallLadder::OverridingDef.overriding_own_def?(node)\n\n")
        moved = edit(gated, /\n  def try_overriding_def_dispatch.*?\n  end\n/m, "")
        moved = edit(moved, "try_overriding_def_dispatch(node)", "CallLadder::OverridingDef.try_call(site, self)",
                     times: 2)
        untested = edit(typer, "dynamic_top if overriding_own_def?(node)\n\n", "dynamic_top if node\n\n")

        expect(failing(moved, rungs: moved_rungs)).to eq([])
        expect(failing(gated)).to eq([:splat_index_read])
        expect(written(read(untested))[:splat_index_read].first).to eq([:undeclared, "dynamic_top"])
      end

      it "reads a gate by its own name: the same answer under another test is no gate" do
        other = edit(typer, "dynamic_top if overriding_own_def?(node)\n\n", "dynamic_top if splat_arguments?(node)\n\n")

        expect(written(read(typer))[:splat_index_read].first).to eq(%i[gate overriding_def])
        expect(written(read(other))[:splat_index_read].first).to eq([:undeclared, "dynamic_top"])
      end
    end

    describe "of a sequence that has moved into a rung module" do
      let(:moved_rungs) do
        homes = { literal_send: "LiteralSend", user_method: "UserMethod", project_singleton: "ProjectSingleton" }
        homes.reduce(rungs) do |table, (name, home)|
          rows(table, name, home: "CallLadder::#{home}", asked_as: %i[try_call])
        end
      end
      let(:moved_entries) { rows(entries, :send_target, home: "CallLadder::LiteralSend", written_in: %i[try_call]) }
      let(:literal_send) do
        <<~RUBY
          module Rigor::Inference::CallLadder::LiteralSend
            module_function

            def try_call(site, typer)
              return own_send_type(site, typer) if own_send?(site, typer)

              target = target_site(site, typer)
              MethodDispatcher.dispatch_site(target) || UserMethod.try_call(target, typer) ||
                ProjectSingleton.try_call(target, typer)
            end
          end
        RUBY
      end
      let(:moved_typer) do
        source = edit(typer, /  def try_literal_send.*?\n  end\n\n/m, "")
        source = edit(source, "try_literal_send(node)", "CallLadder::LiteralSend.try_call(site, self)")
        source = edit(source, "try_user_method_inference(node)", "CallLadder::UserMethod.try_call(site, self)",
                      times: 3)
        edit(source, "try_project_singleton_inference(node)", "CallLadder::ProjectSingleton.try_call(site, self)",
             times: 2)
      end

      it "reads the entry in the module's file, where the module's own methods have no receiver" do
        reading = read(moved_typer, rungs: moved_rungs, entries: moved_entries,
                                    modules: { "CallLadder::LiteralSend" => literal_send })

        expect(written(reading)).to eq(expected(reading))
        expect(written(reading)[:send_target].size).to eq(4)
        expect(reading.stray_sequences).to eq([])
        expect(reading.method_counts).to include("CallLadder::LiteralSend" => 1)
      end

      it "names a module's file by its constant, and reads the typer's modules and the rung modules beside it" do
        writes = "module Rigor::Inference::ExpressionTyper::Writes\nend\n"
        Dir.mktmpdir do |root|
          directory = File.join(root, CallLadderPin::LIB)
          %w[call_ladder expression_typer].each { |name| FileUtils.mkdir_p(File.join(directory, name)) }
          File.write(File.join(directory, "expression_typer.rb"), moved_typer)
          File.write(File.join(directory, "expression_typer/writes.rb"), writes)
          File.write(File.join(directory, "call_ladder/literal_send.rb"), literal_send)

          expect(CallLadderPin.sources(root)).to eq(
            "ExpressionTyper" => moved_typer, "ExpressionTyper::Writes" => writes,
            "CallLadder::LiteralSend" => literal_send
          )
        end
        expect(CallLadderPin.home_of("lib/rigor/inference/call_ladder/project_singleton.rb"))
          .to eq("CallLadder::ProjectSingleton")
      end
    end

    describe "of an exception row" do
      def without(name) = exceptions.reject { |exception| exception.name == name }

      it "fails when the row goes and the code it excuses stays, for the entry and for its branch" do
        drift = read(typer, exceptions: without(:index_read_without_refined))

        expect(expected(drift).slice(:index_read, :splat_index_read).values.map(&:first))
          .to eq([%i[rung refined], %i[rung refined]])
        expect(failing(typer, exceptions: without(:index_read_without_refined))).to eq(%i[index_read splat_index_read])
        expect(written(read(typer, exceptions: without(:splat_index_read)))[:index_read].first)
          .to eq([:undeclared, "splat_index_read_type"])
      end

      it "passes once the code asks the omitted rung ahead of the branch: the fix of #3358 deletes its row" do
        ahead = "    refined = try_refined_dispatch(node)\n    return refined if refined\n"
        fixed = edit(typer, "    return splat_index_read_type(node)", "#{ahead}    return splat_index_read_type(node)")

        expect(failing(fixed, exceptions: without(:index_read_without_refined))).to eq([])
        expect(failing(fixed)).to eq(%i[index_read splat_index_read])
      end
    end

    describe "of a failure" do
      def advice(source, name, **tables)
        reading = read(source, **tables)
        CallLadderPin::Advice.place(reading, reading.places.find { |place| place.name == name })
      end

      it "says nothing of a place whose code and tables agree, and shows both sequences of one that does not" do
        dropped = edit(typer, " || try_user_method_inference(args)", "")

        expect(read(typer).places.map { |place| advice(typer, place.name) }).to all(be_nil)
        expect(advice(dropped, :send_target)).to include(
          "The `send_target` sequence (ExpressionTyper: try_literal_send)",
          "code asks:   own_send_type (ahead), dispatcher, project_singleton",
          "tables give: own_send_type (ahead), dispatcher, user_method, project_singleton"
        )
      end

      it "names the ways out for a call with no row, and that `ahead` cannot take a call on another receiver" do
        shortcut = "    plugin = try_plugin_shortcut(node)\n    return plugin if plugin\n\n"
        added = edit(typer, "    refined = try_refined_dispatch", "#{shortcut}    refined = try_refined_dispatch")
        qualified = edit(typer, "\n    unresolved_call_result(node)\n",
                         "\n    unresolved_call_result(node) || Fallback.untyped\n")

        expect(advice(added, :call)).to include(
          "`try_plugin_shortcut` can answer here", "add its row to RUNGS", "with `call` in `asked_by`",
          "`written_in` of ENTRIES' `call`", "that entry's `ahead`"
        )
        expect(advice(qualified, :call)).to include("`Fallback.untyped` can answer here", "cannot be listed")
      end

      it "names the rung a place leaves out, how its row spells the ask, and the exception row a defect needs" do
        dropped = edit(typer, " || try_user_method_inference(args)", "")
        undispatched = edit(typer, "MethodDispatcher.dispatch(args) || ", "")

        expect(advice(dropped, :send_target)).to include(
          "`user_method` is not asked here", "gives it to `send_target`", "`try_user_method_inference(…)`",
          "add a row to EXCEPTIONS that omits it and names the issue"
        )
        expect(advice(undispatched, :send_target)).to include("`MethodDispatcher.dispatch_site(…)`")
      end

      it "names the exception row to delete, with its issue, once the code asks the rung the row omits" do
        ahead = "    refined = try_refined_dispatch(node)\n    return refined if refined\n"
        fixed = edit(typer, "    return splat_index_read_type(node)", "#{ahead}    return splat_index_read_type(node)")

        expect(advice(fixed, :index_read)).to include(
          "`refined` is asked here", "the exception row `index_read_without_refined`", "(#3358)", "delete that row"
        )
      end

      it "tells a rung its row does not give the entry from one asked in another order, or through no gate" do
        added = edit(typer, "    try_overriding_def_dispatch(node) ||", "    try_local_def_dispatch(node) ||")
        swapped = swap(typer, "try_user_method_inference(args)", "try_project_singleton_inference(args)")
        ungated = edit(typer, "return dynamic_top if overriding_own_def?(node)", "return dynamic_top")

        expect(advice(added, :index_read)).to include("`top_level_def` is asked here", "Add `index_read` to the row")
        expect(advice(swapped, :send_target)).to include("another order than the rows of RUNGS")
        expect(advice(ungated, :splat_index_read))
          .to include("test `overriding_own_def?` and answer `dynamic_top`", "`dynamic_top` can answer here")
      end

      it "says what a place's method may do with a rung, and what a sequence outside the places needs" do
        returns = swap(typer, "return refined if refined", "return literal_send if literal_send")
        hidden = CallLadderPin::Advice.hidden([["ExpressionTyper", :dispatch_miss_result, :user_method]])
        strays = CallLadderPin::Advice.strays([["ExpressionTyper", :fifth, %i[overriding_def dispatch_miss_result]]])

        expect(advice(returns, :call)).to include("directly above its `return x if x`")
        expect(hidden).to include("ExpressionTyper#dispatch_miss_result asks `user_method`", "only as an answer")
        expect(strays).to include("ExpressionTyper#fifth asks overriding_def, dispatch_miss_result", "`written_in`")
      end
    end
  end
end
