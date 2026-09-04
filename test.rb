class A; class B; end; end
class C < A; end

def resolve_class(name)
  return nil unless name.is_a?(::String)

  parts = name.delete_prefix("::").split("::")
  return nil if parts.empty?

  mod = ::Object
  parts.each do |part|
    return nil unless mod.is_a?(::Module) && mod.const_defined?(part, false)
    return nil if mod.autoload?(part)

    mod = mod.const_get(part, false)
  end
  mod.is_a?(::Module) ? mod : nil
rescue ::StandardError, ::ScriptError, ::SystemExit
  nil
end

p resolve_class("C::B")
