require "resolv"
require "rigor/testing"
include Rigor::Testing

# Issue #2828 — a method type variable `T` a positional parameter spells
# `singleton(T)` binds to the instance type of the class object the call
# passes. `Resolv::DNS#getresources` answered `Array[Resolv::DNS::Resource]`
# whatever the typeclass, so a record's own reader (`MX#exchange`) reported
# `call.undefined-method`. Nothing in this file reports unless the line is
# marked.

class Widget; end
class Gadget < Widget; end

# `Factory`'s methods live only in `sig/`: a method the project source defines
# on the resolved class declines argument binding (`arg_binding_permitted?`).
# No method in this file is called, so the fixture loads under MRI.
class Factory; end

def resolver_lookups
  dns = Resolv::DNS.new
  domain = "example.com"
  exchanges = dns.getresources(domain, Resolv::DNS::Resource::IN::MX)
  assert_type("Array[Resolv::DNS::Resource::IN::MX]", exchanges)
  exchanges.map { |mx| mx.exchange }

  dns.getresources(domain, Resolv::DNS::Resource::IN::A).map { |a| a.address }
  dns.getresources(domain, Resolv::DNS::Resource::IN::AAAA).map { |a| a.address }

  single = dns.getresource(domain, Resolv::DNS::Resource::IN::MX)
  assert_type("Resolv::DNS::Resource::IN::MX", single)
  single.preference

  dns.each_resource(domain, Resolv::DNS::Resource::IN::MX) do |mx|
    assert_type("Resolv::DNS::Resource::IN::MX", mx)
    mx.exchange
  end

  dns.getresources(domain, Resolv::DNS::Resource::IN::MX).first.nosuch # GENUINE-UNDEFINED
end

# A typeclass the engine cannot read as one class object binds nothing: the
# base signature answers, as before the overlay.
def resolver_untyped_typeclass(domain, typeclass)
  dns = Resolv::DNS.new
  dns.getresources(domain, typeclass).map { |record| record.exchange }
end

def resolver_union_typeclass(flag)
  dns = Resolv::DNS.new
  domain = "example.com"
  typeclass = flag ? Resolv::DNS::Resource::IN::A : Resolv::DNS::Resource::IN::AAAA
  records = dns.getresources(domain, typeclass)
  assert_type("Array[Resolv::DNS::Resource::IN::A | Resolv::DNS::Resource::IN::AAAA]", records)
  records.map { |record| record.address }
end

def project_generic
  factory = Factory.new
  assert_type("Widget", factory.build(Widget))
  assert_type("Gadget", factory.build_widget(Gadget))
  factory.build(Widget).nosuch # GENUINE-UNDEFINED
end

# A class outside the declared bound (`[T < Widget]`) binds nothing.
def project_generic_outside_bound
  factory = Factory.new
  assert_type("Dynamic[top]", factory.build_widget(String))
end

# The issue's shape: a domain the engine cannot type makes both overloads
# candidates, and the join stays silent.
def resolver_untyped_domain(domain)
  dns = Resolv::DNS.new
  dns.getresources(domain, Resolv::DNS::Resource::IN::MX).map { |mx| mx.exchange.to_s }
end
