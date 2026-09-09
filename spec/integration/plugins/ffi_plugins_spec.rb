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

    it "identifies nominal opaque pointer typedefs per WD4 with proper \\z anchor" do
      expect(Rigor::Plugin::FFI::Types.nominal_opaque_pointer?(:sass_context_ptr)).to be true
      expect(Rigor::Plugin::FFI::Types.nominal_opaque_pointer?(:window_handle)).to be true
      expect(Rigor::Plugin::FFI::Types.nominal_opaque_pointer?(:SassContextPtr)).to be true
      expect(Rigor::Plugin::FFI::Types.nominal_opaque_pointer?(:plain_int)).to be false
      expect(Rigor::Plugin::FFI::Types.nominal_opaque_pointer?(:sass_context_ptrz)).to be false
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

    it "correctly parses attach_function with string C name and constant args" do
      code = "attach_function :foo, \"foo_c\", ARGS, :int"
      call_node = Prism.parse(code).value.statements.body.first
      fact = Rigor::Plugin::FFI::Analyzer.extract_attach_function(call_node)
      expect(fact.ruby_name).to eq(:foo)
      expect(fact.c_name).to eq(:foo_c)
      expect(fact.arg_types).to eq([:ARGS])
      expect(fact.return_type).to eq(:int)
    end

    it "supports callbacks in discovery and typing" do
      callbacks = { my_cb: { params: [:int], return_type: :void } }
      ret_type = Rigor::Plugin::FFI::Types.return_type_for(:my_cb, callbacks: callbacks)
      expect(ret_type.describe(:short)).to eq("FFI::Function")

      param_type = Rigor::Plugin::FFI::Types.param_type_for(:my_cb, callbacks: callbacks)
      expect(param_type).to be_a(Rigor::Type::Union)
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

    it "does not match dynamic_return for non-FFI receivers" do
      catalog = Rigor::Plugin::FFI::FFICatalog.new(
        functions: {
          size: [
            Rigor::Plugin::FFI::AttachFunctionFact.new(
              ruby_name: :size,
              c_name: :size,
              arg_types: [],
              return_type: :int,
              node: nil,
              receiver_name: "MyLib"
            )
          ]
        },
        functions_by_receiver: {},
        libraries: Set.new(["MyLib"]),
        structs: { "MyStruct" => { size: :int } }
      )
      expect(catalog.libraries).not_to include("Array")
      expect(catalog.struct_names).not_to include("Array")
      expect(catalog.function_for("Array", :size)).to be_nil
    end

    it "identifies assigned value node for struct []= as the last argument" do
      code = "struct[:id] = 5"
      call_node = Prism.parse(code).value.statements.body.first
      expect(call_node.name).to eq(:[]=)
      expect(call_node.arguments.arguments.last).to be_a(Prism::IntegerNode)
    end
  end

  describe "sub-plugins" do
    it "loads rigor-sassc with manifest id sassc" do
      expect(Rigor::Plugin::SassC.manifest.id).to eq("sassc")
    end

    it "loads rigor-ethon with manifest id ethon" do
      expect(Rigor::Plugin::Ethon.manifest.id).to eq("ethon")
    end

    it "loads rigor-rbnacl with manifest id rbnacl and preserves nested submodule receivers and parses constant args" do
      expect(Rigor::Plugin::RbNaCl.manifest.id).to eq("rbnacl")

      code = "sodium_function :crypto_sign_ed25519_seed_keypair, :crypto_sign_ed25519_seed_keypair, ARGS, :int"
      call_node = Prism.parse(code).value.statements.body.first
      recognizer = Rigor::Plugin::FFI.binding_recognizers.find { |r| r.name == :sodium_function }
      facts = recognizer.recognize(call_node, "RbNaCl::Signatures::Ed25519")
      expect(facts.first.receiver_name).to eq("RbNaCl::Signatures::Ed25519")
      expect(facts.first.arg_types).to eq([:ARGS])
      expect(facts.first.return_type).to eq(:int)
    end

    it "loads rigor-ffi-rzmq with manifest id ffi-rzmq" do
      expect(Rigor::Plugin::FFIRZMQ.manifest.id).to eq("ffi-rzmq")
    end
  end

  # Issue #918 — WD4's `exceptions` and WD6's `target` are read from `config` inside the plugin, but the
  # manifest declared no `config_schema`, so `Manifest#validate_config` rejected both as unknown before a
  # single line of the plugin's own logic ever ran. These drive the real `Rigor::Analysis::Runner`
  # against a `.rigor.yml`-shaped plugin entry (not the bare unit calls above) to prove the config keys
  # both validate AND change the produced type.
  describe "configuration (#918)" do
    include Rigor::IntegrationSupport::PluginHelpers

    let(:plugin_class) { Rigor::Plugin::FFI }
    let(:typedef_source) do
      <<~RUBY
        module MyLib
          extend FFI::Library
          typedef :pointer, :my_ptr
          attach_function :open, [], :my_ptr
        end

        Rigor.dump_type(MyLib.open)
      RUBY
    end
    let(:pointer_source) do
      <<~RUBY
        module MyLib
          extend FFI::Library
          attach_function :open, [], :pointer
        end

        Rigor.dump_type(MyLib.open)
      RUBY
    end

    def dumps(result)
      result.diagnostics.select { |d| d.qualified_rule == "dump.type" }.map(&:message)
    end

    it "treats a typedef alias as the nominal opaque-pointer type by default (WD4)" do
      result = run_plugin(source: typedef_source)
      expect(dumps(result)).to eq(["dump_type: MyLib::MyPtr"])
    end

    it "widens the nominal exception back to FFI::Pointer once `exceptions` names it (WD4)" do
      result = run_plugin(
        source: typedef_source,
        plugin_entry: { "gem" => "rigor-ffi", "config" => { "exceptions" => ["my_ptr"] } }
      )
      expect(dumps(result)).to eq(["dump_type: FFI::Pointer"])
    end

    it "returns FFI::Pointer for the ffi-gem target by default" do
      result = run_plugin(source: pointer_source)
      expect(dumps(result)).to eq(["dump_type: FFI::Pointer"])
    end

    it "returns Integer instead once `target: ffx` is forced through config (WD6)" do
      result = run_plugin(
        source: pointer_source,
        plugin_entry: { "gem" => "rigor-ffi", "config" => { "target" => "ffx" } }
      )
      expect(dumps(result)).to eq(["dump_type: Integer"])
    end

    it "rejects an unknown config key instead of silently ignoring it" do
      errors = Rigor::Plugin::FFI.manifest.validate_config({ "bogus" => true })
      expect(errors).to include(a_string_matching(/unknown config key "bogus"/))
    end
  end
end
