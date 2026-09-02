# frozen_string_literal: true

require "rigor"
require "rigor/rbs_extended/envelope_scanner"

# ADR-103 WD10 / issue #388 — the `%a{pure}` sweep over
# `plugins/rigor-activesupport-core-ext/sig/active_support/core_ext.rbs`.
#
# This pins the audit at the RBS-declaration level: every method this file claims is pure actually
# carries `%a{pure}` (read through the real {Rigor::RbsExtended::EnvelopeScanner}, not a text grep — a
# grep would false-positive on this file's own "NOT `%a{pure}`" explanatory prose), and the well-known
# impure shapes — bang mutators, `try` / `try!`, `constantize`, the clock / zone family — carry no
# annotation. The end-to-end "a caller of only pure core_ext methods reads exhaustive-∅" claim is
# `spec/rigor/effects/core_ext_purity_spec.rb`.
#
# The two tables below live at file scope, not inside the example group (RuboCop's
# `Lint/ConstantDefinitionInBlock` / `RSpec/LeakyConstantDeclaration` — the same reason
# `RAILS_PLUGIN_GEMS` sits outside `RSpec.describe` in `spec/rigor/effects/rails_layer_spec.rb`).

# Every method this file annotates `%a{pure}`, one row per `Class#method` / `Class.method` key —
# generated from the file itself at authoring time and then reviewed by hand; a name silently dropped
# from the RBS (or never annotated) fails `#has every annotated method`, and a name added here without
# the RBS actually carrying `%a{pure}` fails `#carries no extra annotations`.
CORE_EXT_PURE_KEYS = %w[
  ActiveSupport::Duration#in_days ActiveSupport::Duration#in_hours ActiveSupport::Duration#in_minutes
  ActiveSupport::Duration#in_months ActiveSupport::Duration#in_seconds ActiveSupport::Duration#in_weeks
  ActiveSupport::Duration#in_years ActiveSupport::Duration#iso8601 ActiveSupport::Duration#parts
  ActiveSupport::Duration#to_f ActiveSupport::Duration#to_i
  Array#compact_blank Array#exclude? Array#fifth Array#forty_two Array#fourth Array#from
  Array#in_groups Array#in_groups_of Array#inquiry Array#second Array#split Array#third Array#to
  Array.wrap
  Date#acts_like_date? Date#advance Date#beginning_of_month Date#beginning_of_year
  Date#end_of_month Date#end_of_year Date#to_time Date#tomorrow Date#yesterday
  DateTime#acts_like_time? DateTime#ago DateTime#beginning_of_day DateTime#beginning_of_hour
  DateTime#beginning_of_minute DateTime#end_of_day DateTime#end_of_hour DateTime#end_of_minute
  DateTime#since DateTime#tomorrow DateTime#utc DateTime#yesterday
  Enumerable#compact_blank Enumerable#exclude? Enumerable#excluding Enumerable#including
  Enumerable#index_by Enumerable#index_with Enumerable#maximum Enumerable#minimum Enumerable#pick
  Enumerable#pluck Enumerable#sole Enumerable#without
  FalseClass#blank? FalseClass#present?
  Float#byte Float#bytes Float#day Float#days Float#gigabyte Float#gigabytes Float#hour Float#hours
  Float#kilobyte Float#kilobytes Float#megabyte Float#megabytes Float#minute Float#minutes
  Float#month Float#months Float#second Float#seconds Float#week Float#weeks Float#year Float#years
  Hash#assert_valid_keys Hash#compact_blank Hash#deep_dup Hash#deep_merge Hash#deep_stringify_keys
  Hash#deep_symbolize_keys Hash#deep_transform_keys Hash#deep_transform_values Hash#reverse_merge
  Hash#stringify_keys Hash#symbolize_keys Hash#with_indifferent_access Hash#without
  Integer#byte Integer#bytes Integer#day Integer#days Integer#exabyte Integer#exabytes
  Integer#fortnight Integer#fortnights Integer#gigabyte Integer#gigabytes Integer#hour Integer#hours
  Integer#kilobyte Integer#kilobytes Integer#megabyte Integer#megabytes Integer#minute
  Integer#minutes Integer#month Integer#months Integer#multiple_of? Integer#ordinal
  Integer#ordinalize Integer#petabyte Integer#petabytes Integer#second Integer#seconds
  Integer#terabyte Integer#terabytes Integer#week Integer#weeks Integer#year Integer#years
  NilClass#blank? NilClass#duplicable? NilClass#presence NilClass#present? NilClass#try NilClass#try!
  Object#acts_like? Object#blank? Object#in? Object#presence Object#present?
  String#at String#camelcase String#camelize String#classify String#dasherize String#deconstantize
  String#demodulize String#ends_with? String#exclude? String#first String#foreign_key String#from
  String#html_safe String#html_safe? String#humanize String#indent String#inquiry String#last
  String#mb_chars String#pluralize String#remove String#singularize String#squish
  String#starts_with? String#strip_heredoc String#tableize String#titlecase String#titleize
  String#to String#truncate String#truncate_bytes String#truncate_words String#underscore
  String#upcase_first
  Time#acts_like_time? Time#advance Time#ago Time#all_day Time#at_beginning_of_day
  Time#at_end_of_day Time#at_midnight Time#at_noon Time#beginning_of_day Time#beginning_of_hour
  Time#beginning_of_minute Time#beginning_of_month Time#beginning_of_year Time#change Time#end_of_day
  Time#end_of_hour Time#end_of_minute Time#end_of_month Time#end_of_year Time#in Time#midday
  Time#midnight Time#noon Time#since Time#tomorrow Time#yesterday
  TrueClass#blank? TrueClass#present?
  ERB::Util.html_escape_once
].freeze

# The interesting NOT-pure cases: one per reason a method was skipped, plus every same-named pair that
# diverges by class (`Time#ago` is pure, `Date#ago` is not; `Time#beginning_of_day` is pure,
# `Date#beginning_of_day` is not) — the exact shape a careless class-wide annotation would get wrong.
CORE_EXT_NOT_PURE_KEYS = %w[
  ActiveSupport::Duration#ago ActiveSupport::Duration#until ActiveSupport::Duration#before
  ActiveSupport::Duration#since ActiveSupport::Duration#from_now ActiveSupport::Duration#after
  Object#as_json Object#try Object#try!
  String#constantize String#safe_constantize String#parameterize
  String#squish! String#remove! String#indent!
  String#to_time String#to_date String#to_datetime String#to_hours
  Time.current Time.zone Time.zone=
  Time#beginning_of_week Time#end_of_week Time#at_beginning_of_week Time#at_end_of_week
  Date.current Date.yesterday Date.tomorrow
  Date.beginning_of_week Date.end_of_week Date.beginning_of_month Date.end_of_month
  Date.beginning_of_year Date.end_of_year
  Date#beginning_of_week Date#end_of_week Date#ago Date#since Date#beginning_of_day
  Date#midnight Date#at_midnight Date#at_beginning_of_day Date#end_of_day Date#at_end_of_day
  Date#all_day
  DateTime#in_time_zone
  Array#to_sentence Array#to_formatted_s Array#to_fs Array#to_xml Array#extract!
  Array#compact_blank!
  Hash#symbolize_keys! Hash#deep_symbolize_keys! Hash#stringify_keys! Hash#deep_stringify_keys!
  Hash#deep_transform_keys! Hash#deep_transform_values! Hash#deep_merge! Hash#except!
  Hash#to_query Hash#to_param Hash#to_xml Hash#compact_blank! Hash#reverse_merge! Hash#slice!
].freeze

RSpec.describe "plugins/rigor-activesupport-core-ext %a{pure} sweep (#388)" do
  def rbs_path
    File.expand_path(
      "../../../plugins/rigor-activesupport-core-ext/sig/active_support/core_ext.rbs", __dir__
    )
  end

  def scanned
    @scanned ||= Rigor::RbsExtended::EnvelopeScanner.scan(
      sources: [[rbs_path, File.read(rbs_path)]], registry: Rigor::Effects::Registry.default
    )
  end

  # `%a{pure}` reads as the empty envelope — a present entry with an empty bound. Since this file never
  # writes `%a{rigor:v1:effect …}`, any entry at all means `%a{pure}`.
  def pure?(key)
    envelope = scanned.method_envelopes[key]
    !envelope.nil? && envelope.bound.to_a.empty?
  end

  it "has every annotated method carrying %a{pure}" do
    missing = CORE_EXT_PURE_KEYS.reject { |key| pure?(key) }
    expect(missing).to be_empty, "expected these keys to read %a{pure}: #{missing.join(', ')}"
  end

  it "carries no extra %a{pure} beyond the audited set" do
    extra = scanned.method_envelopes.keys.select { |key| pure?(key) } - CORE_EXT_PURE_KEYS
    expect(extra).to be_empty, "found %a{pure} on keys not in the audited PURE_KEYS list: #{extra.join(', ')}"
  end

  it "leaves the well-known impure shapes unannotated: dispatch, bang, constant resolution, the clock" do
    annotated = CORE_EXT_NOT_PURE_KEYS.select { |key| pure?(key) }
    expect(annotated).to be_empty, "expected these keys to carry no %a{pure}: #{annotated.join(', ')}"
  end

  it "diverges on the same method name between Time and Date, verified against the vendored source" do
    expect(pure?("Time#ago")).to be(true)
    expect(pure?("Date#ago")).to be(false)
    expect(pure?("Time#beginning_of_day")).to be(true)
    expect(pure?("Date#beginning_of_day")).to be(false)
  end
end
