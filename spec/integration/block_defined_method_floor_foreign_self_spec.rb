# frozen_string_literal: true

require "spec_helper"

# Issue #3163 — the non-escaping floor for a method a block defines leaves an instance variable out when the block
# itself runs on another object (`foreign_self_block?`). Every self-rebinding call classifies `:unknown` today, so
# no program reaches that term through the non-escaping seam: the escape analysis is stubbed here to pin it for the
# day it learns to call one non-escaping, as the sibling content seams guard theirs.
RSpec.describe "the block-defined method floor under a foreign-self block", type: :runner do
  def dumped_types(source)
    analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source})).diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  before do
    allow_any_instance_of(Rigor::Inference::StatementEvaluator) # rubocop:disable RSpec/AnyInstance
      .to receive(:classify_closure_escape).and_return(:non_escaping)
  end

  it "keeps this object's instance variable when the block runs on a class object" do
    expect(dumped_types(<<~RUBY)).to eq(["Array[0]"])
      class ForeignSelfFloor
        def run
          @fs = [0]
          String.instance_eval do
            def foreign_helper
              @fs << 1 if @fs
            end
          end
          dump_type(@fs)
        end
      end
    RUBY
  end

  it "floors it when the block runs on self" do
    expect(dumped_types(<<~RUBY)).to eq(["Array[Dynamic[top]]"])
      class OwnSelfFloor
        def run
          @fs = [0]
          [1].each do
            def own_helper
              @fs << 1 if @fs
            end
          end
          dump_type(@fs)
        end
      end
    RUBY
  end
end
