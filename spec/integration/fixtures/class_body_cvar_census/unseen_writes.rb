# 1: memoised singleton
class Registry
  @@instance = nil
  def self.instance; @@instance ||= new; end
  def self.name_of; instance; @@instance.label.upcase; end
  def label; "reg"; end
end
puts Registry.name_of
# 2: counter
class Counter
  @@count = 0
  def self.hit; @@count += 1; end
  def self.report; puts "hits" if @@count > 0; end
end
Counter.hit; Counter.report
# 3: module cvar written by an includer
module Shared
  @@conn = nil
  def conn_name; @@conn.upcase; end
end
class User
  include Shared
  def connect; @@conn = "db"; end
end
u = User.new; u.connect; puts u.conn_name
# 4: Devise-style accessor macro, dynamic name
module Config
  def self.mattr(name)
    define_singleton_method("#{name}=") { |v| class_variable_set("@@#{name}", v) }
  end
  mattr :secret
  @@secret = nil
  def self.secret_size; @@secret.size; end
end
Config.secret = "abc"; puts Config.secret_size
# 5: explicit receiver
class Explicit
  @@x = nil
  def self.len; @@x.length; end
end
Explicit.class_variable_set(:@@x, "four"); puts Explicit.len
# 6: self.class receiver from an instance method
class Inst
  @@x = nil
  def put; self.class.class_variable_set(:@@x, "five"); end
  def len; @@x.length; end
end
i = Inst.new; i.put; puts i.len
# 7: superclass initialises, subclass writes, superclass reads
class Base
  @@state = nil
  def state_len; @@state.length; end
end
class Sub < Base
  def boot; @@state = "ready"; end
end
Sub.new.boot; puts Base.new.state_len
# 8: literal collection mutated in place
class Coll
  @@list = [:a]
  @@map = { a: 1 }
  @@str = "ab"
  def self.grow; @@list << :b; @@map[:b] = 2; @@str << "c"; end
  def self.report
    puts "two" if @@list.size == 2
    puts "hasb" if @@map.key?(:b)
    puts "abc" if @@str == "abc"
  end
end
Coll.grow; Coll.report
# 9: send / interpolated name on self
class Refl
  @@x = nil
  @@y = nil
  def self.w; send(:class_variable_set, :@@x, "s"); class_variable_set(:"@@#{"y"}", "t"); end
  def self.len; @@x.length + @@y.length; end
end
Refl.w; puts Refl.len
# 10: class_eval string
class Ev
  @@x = nil
  class_eval "@@x = 'e'"
  def self.len; @@x.length; end
end
puts Ev.len
# 11: issue-form fold on &&=
class Flag
  @@on = true
  def self.off; @@on &&= false; end
  def self.report; puts "off" unless @@on; end
end
Flag.off; Flag.report
