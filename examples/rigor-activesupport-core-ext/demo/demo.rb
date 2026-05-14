# frozen_string_literal: true

# Demo: every method in this file is an ActiveSupport core_ext
# extension. Without the bundle's `sig/` directory wired into
# `.rigor.yml`'s `signature_paths:`, every line emits a
# `call.undefined-method` diagnostic. With the bundle in scope,
# they all type-check cleanly.

# Duration multipliers (Integer / Float)
5.minutes
3.hours
7.days
2.5.hours

# Bytes multipliers
10.megabytes
2.gigabytes

# Time / Date calculations
Time.current
Time.zone
Date.current
Date.yesterday
Date.tomorrow

# String inflections
"user_account".camelize       # => "UserAccount"
"UserAccount".underscore      # => "user_account"
"posts".singularize           # => "post"
"post".pluralize              # => "posts"
"  hello   world  ".squish    # => "hello world"
"User::Account".demodulize    # => "Account"
"<b>bold</b>".html_safe       # => SafeBuffer "<b>bold</b>"
"long text".truncate(5)       # => "lo..."

# String predicate aliases (in addition to core start_with? / end_with?)
"hello".starts_with?("he")
"hello".ends_with?("lo")

# Array.wrap — the dominant Rails idiom
Array.wrap(nil)               # => []
Array.wrap("x")               # => ["x"]
Array.wrap([1, 2])            # => [1, 2]

# Array#to_sentence, #in_groups_of, #second
%w[a b c].to_sentence         # => "a, b, and c"
(1..10).to_a.in_groups_of(3)
[10, 20, 30].second           # => 20

# Hash extensions
{ "a" => 1 }.symbolize_keys   # => {:a => 1}
{ a: 1, b: { c: 2 } }.deep_dup
{ a: 1 }.with_indifferent_access

# Object universal helpers
nil.blank?                    # => true
"".blank?                     # => true
"hello".present?              # => true
nil.try(:length)              # => nil
"abc".try(:length)            # => 3
