# frozen_string_literal: true

require "spec_helper"

FFI_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-ffi/lib", __dir__)
$LOAD_PATH.unshift(FFI_PLUGIN_LIB) unless $LOAD_PATH.include?(FFI_PLUGIN_LIB)
require "rigor-ffi"

SASSC_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-sassc/lib", __dir__)
$LOAD_PATH.unshift(SASSC_PLUGIN_LIB) unless $LOAD_PATH.include?(SASSC_PLUGIN_LIB)
require "rigor-sassc"

ETHON_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-ethon/lib", __dir__)
$LOAD_PATH.unshift(ETHON_PLUGIN_LIB) unless $LOAD_PATH.include?(ETHON_PLUGIN_LIB)
require "rigor-ethon"

RBNACL_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-rbnacl/lib", __dir__)
$LOAD_PATH.unshift(RBNACL_PLUGIN_LIB) unless $LOAD_PATH.include?(RBNACL_PLUGIN_LIB)
require "rigor-rbnacl"

FFI_RZMQ_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-ffi-rzmq/lib", __dir__)
$LOAD_PATH.unshift(FFI_RZMQ_PLUGIN_LIB) unless $LOAD_PATH.include?(FFI_RZMQ_PLUGIN_LIB)
require "rigor-ffi-rzmq"

RSpec.describe "FFI plugin family" do
  describe "core plugin (rigor-ffi)" do
    it "has id ffi" do
      expect(Rigor::Plugin::FFI.manifest.id).to eq("ffi")
    end

    it "recognizes the 25 primitive type symbols" do
      expect(Rigor::Plugin::FFI::Types::FFX_PRIMITIVE_TYPES.size).to eq(25)
    end

    it "identifies nominal opaque pointer typedefs per WD4" do
      expect(Rigor::Plugin::FFI::Types.nominal_opaque_pointer?(:sass_context_ptr)).to be true
      expect(Rigor::Plugin::FFI::Types.nominal_opaque_pointer?(:window_handle)).to be true
      expect(Rigor::Plugin::FFI::Types.nominal_opaque_pointer?(:SassContextPtr)).to be true
      expect(Rigor::Plugin::FFI::Types.nominal_opaque_pointer?(:plain_int)).to be false
      expect(Rigor::Plugin::FFI::Types.nominal_opaque_pointer?(:my_ptr, exceptions: ["my_ptr"])).to be false
    end

    it "widens pointer parameter inputs universally per WD7" do
      param_type = Rigor::Plugin::FFI::Types.param_type_for(:pointer)
      expect(param_type).to be_a(Rigor::Type::Union)
    end

    it "detects target from extconf and lockfile per WD6" do
      expect(Rigor::Plugin::FFI::TargetDetector.detect(root: nil, config: { "target" => "ffx" })).to eq(:ffx)
      expect(Rigor::Plugin::FFI::TargetDetector.detect(root: nil, config: { "target" => "auto" })).to eq(:ffi)
    end

    it "flags ffx unsupported constructs with proper diagnostic rules per WD5" do
      parsed = Prism.parse("callback :cb, [:int], :void").value
      call_node = parsed.statements.body.first
      diags = Rigor::Plugin::FFI::Analyzer.ffx_diagnostics_for_call(call_node, path: "test.rb", target: :ffx)
      expect(diags.map(&:rule)).to include("ffx.unsupported-callback")

      parsed_struct = Prism.parse("class S < FFI::Struct; end").value
      class_node = parsed_struct.statements.body.first
      diags_struct = Rigor::Plugin::FFI::Analyzer.ffx_diagnostics_for_class(class_node, path: "test.rb", target: :ffx)
      expect(diags_struct.map(&:rule)).to include("ffx.unsupported-struct")

      parsed_va = Prism.parse("attach_function :foo, [:int, :varargs], :void").value
      call_va = parsed_va.statements.body.first
      diags_va = Rigor::Plugin::FFI::Analyzer.ffx_diagnostics_for_call(call_va, path: "test.rb", target: :ffx)
      expect(diags_va.map(&:rule)).to include("ffx.unsupported-varargs")
    end
  end

  describe "sub-plugins" do
    it "loads rigor-sassc with manifest id sassc" do
      expect(Rigor::Plugin::SassC.manifest.id).to eq("sassc")
    end

    it "loads rigor-ethon with manifest id ethon" do
      expect(Rigor::Plugin::Ethon.manifest.id).to eq("ethon")
    end

    it "loads rigor-rbnacl with manifest id rbnacl" do
      expect(Rigor::Plugin::RbNaCl.manifest.id).to eq("rbnacl")
    end

    it "loads rigor-ffi-rzmq with manifest id ffi-rzmq" do
      expect(Rigor::Plugin::FFIRZMQ.manifest.id).to eq("ffi-rzmq")
    end
  end
end
