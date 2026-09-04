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
#
# The date/time family is split into one table PER RECEIVER CLASS, and not only to stay under
# `Metrics/CollectionLiteralLength`: it is the part of the audit that DIVERGES by receiver class for the
# same method name — `Time#ago` is pure and `Date#ago` is not — so the reviewer wants to read one class's
# verdicts as a block and compare it against the next, rather than find the three spellings of a name
# scattered through one alphabetical list. Reading the three tables side by side is how you see that
# `Date` is the odd one out: on `Date` the whole `beginning_of_day` / `middle_of_day` / `all_day` family
# routes through `in_time_zone` and reads `Time.zone`, while on `Time` and `DateTime` the same names are
# receiver-local arithmetic (#670).
CORE_EXT_PURE_DATE_KEYS = %w[
  Date#acts_like_date? Date#advance Date#all_month Date#all_quarter Date#all_year
  Date#at_beginning_of_month Date#at_beginning_of_quarter Date#at_beginning_of_year
  Date#at_end_of_month Date#at_end_of_quarter Date#at_end_of_year Date#beginning_of_month
  Date#beginning_of_quarter Date#beginning_of_year Date#change Date#days_ago Date#days_since
  Date#end_of_month Date#end_of_quarter Date#end_of_year Date#last_month Date#last_quarter
  Date#last_weekday Date#last_year Date#monday Date#months_ago Date#months_since
  Date#next_occurring Date#next_quarter Date#on_weekday? Date#on_weekend? Date#prev_occurring
  Date#prev_quarter Date#prev_weekday Date#quarter Date#sunday Date#to_time Date#tomorrow
  Date#weeks_ago Date#weeks_since Date#years_ago Date#years_since Date#yesterday
].freeze

CORE_EXT_PURE_DATETIME_KEYS = %w[
  DateTime#acts_like_time? DateTime#advance DateTime#ago DateTime#all_day DateTime#all_month
  DateTime#all_quarter DateTime#all_year DateTime#at_beginning_of_day
  DateTime#at_beginning_of_hour DateTime#at_beginning_of_minute DateTime#at_beginning_of_month
  DateTime#at_beginning_of_quarter DateTime#at_beginning_of_year DateTime#at_end_of_day
  DateTime#at_end_of_hour DateTime#at_end_of_minute DateTime#at_end_of_month
  DateTime#at_end_of_quarter DateTime#at_end_of_year DateTime#at_midday DateTime#at_middle_of_day
  DateTime#at_midnight DateTime#at_noon DateTime#beginning_of_day DateTime#beginning_of_hour
  DateTime#beginning_of_minute DateTime#beginning_of_month DateTime#beginning_of_quarter
  DateTime#beginning_of_year DateTime#change DateTime#days_ago DateTime#days_since
  DateTime#end_of_day DateTime#end_of_hour DateTime#end_of_minute DateTime#end_of_month
  DateTime#end_of_quarter DateTime#end_of_year DateTime#formatted_offset DateTime#getgm
  DateTime#getutc DateTime#gmtime DateTime#in DateTime#last_month DateTime#last_quarter
  DateTime#last_weekday DateTime#last_year DateTime#midday DateTime#middle_of_day
  DateTime#midnight DateTime#monday DateTime#months_ago DateTime#months_since
  DateTime#next_occurring DateTime#next_quarter DateTime#noon DateTime#nsec
  DateTime#prev_occurring DateTime#prev_quarter DateTime#prev_weekday
  DateTime#seconds_since_midnight DateTime#seconds_until_end_of_day DateTime#since
  DateTime#subsec DateTime#sunday DateTime#to_f DateTime#to_i DateTime#tomorrow DateTime#usec
  DateTime#utc DateTime#utc? DateTime#utc_offset DateTime#weeks_ago DateTime#weeks_since
  DateTime#years_ago DateTime#years_since DateTime#yesterday
].freeze

CORE_EXT_PURE_TIME_KEYS = %w[
  Time#acts_like_time? Time#advance Time#ago Time#all_day Time#at_beginning_of_day
  Time#at_end_of_day Time#at_midnight Time#at_noon Time#beginning_of_day Time#beginning_of_hour
  Time#beginning_of_minute Time#beginning_of_month Time#beginning_of_year Time#change Time#end_of_day
  Time#end_of_hour Time#end_of_minute Time#end_of_month Time#end_of_year Time#in Time#midday
  Time#midnight Time#noon Time#since Time#tomorrow Time#yesterday
  Time#all_month Time#all_quarter Time#all_year Time#at_beginning_of_hour
  Time#at_beginning_of_minute Time#at_beginning_of_month Time#at_beginning_of_quarter
  Time#at_beginning_of_year Time#at_end_of_hour Time#at_end_of_minute Time#at_end_of_month
  Time#at_end_of_quarter Time#at_end_of_year Time#at_midday Time#at_middle_of_day
  Time#beginning_of_quarter Time#days_ago Time#days_since Time#end_of_quarter Time#formatted_offset
  Time#last_month Time#last_quarter Time#last_weekday Time#last_year Time#middle_of_day Time#monday
  Time#months_ago Time#months_since Time#next_day Time#next_month Time#next_occurring
  Time#next_quarter Time#next_year Time#on_weekday? Time#on_weekend? Time#prev_day Time#prev_month
  Time#prev_occurring Time#prev_quarter Time#prev_weekday Time#prev_year Time#quarter Time#rfc3339
  Time#sec_fraction Time#seconds_since_midnight Time#seconds_until_end_of_day Time#sunday
  Time#weeks_ago Time#weeks_since Time#years_ago Time#years_since
].freeze

CORE_EXT_PURE_DATE_AND_TIME_KEYS =
  (CORE_EXT_PURE_DATE_KEYS + CORE_EXT_PURE_DATETIME_KEYS + CORE_EXT_PURE_TIME_KEYS).freeze

CORE_EXT_PURE_OTHER_KEYS = %w[
  ActiveSupport::Duration#in_days ActiveSupport::Duration#in_hours ActiveSupport::Duration#in_minutes
  ActiveSupport::Duration#in_months ActiveSupport::Duration#in_seconds ActiveSupport::Duration#in_weeks
  ActiveSupport::Duration#in_years ActiveSupport::Duration#iso8601 ActiveSupport::Duration#parts
  ActiveSupport::Duration#to_f ActiveSupport::Duration#to_i
  Array#compact_blank Array#exclude? Array#fifth Array#forty_two Array#fourth Array#from
  Array#in_groups Array#in_groups_of Array#inquiry Array#second Array#split Array#third Array#to
  Array.wrap
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
  TrueClass#blank? TrueClass#present?
  ERB::Util.html_escape_once
].freeze

CORE_EXT_PURE_KEYS = (CORE_EXT_PURE_OTHER_KEYS + CORE_EXT_PURE_DATE_AND_TIME_KEYS).freeze

# The interesting NOT-pure cases: one per reason a method was skipped, plus every same-named pair that
# diverges by class (`Time#ago` is pure, `Date#ago` is not; `Time#beginning_of_day` is pure,
# `Date#beginning_of_day` is not) — the exact shape a careless class-wide annotation would get wrong.
#
# Two rows here are pure in fact and bare on purpose. `Date#readable_inspect` / `#default_inspect` ARE
# pure on a `Date` receiver (`strftime` and the original `inspect`), but `DateTime < Date`, so an
# envelope on the `Date` row reaches `DateTime` — where `readable_inspect` is `to_fs(:rfc822)` over the
# mutable `Time::DATE_FORMATS` and is NOT pure. Under-claiming an envelope costs precision;
# over-claiming one is unsound. These two lines are what stops someone "completing" the sweep (#670).
CORE_EXT_NOT_PURE_KEYS = %w[
  Object#as_json Object#try Object#try!
  String#constantize String#safe_constantize String#parameterize
  String#squish! String#remove! String#indent!
  String#to_time String#to_date String#to_datetime String#to_hours
  Time.current Time.zone Time.zone=
  Time#beginning_of_week Time#end_of_week Time#at_beginning_of_week Time#at_end_of_week
  Time#all_week Time#days_to_week_start Time#next_week Time#next_weekday Time#prev_week
  Time#last_week
  Time#today? Time#tomorrow? Time#yesterday? Time#next_day? Time#prev_day? Time#past? Time#future?
  Time#before? Time#after? Time#to_fs Time#to_formatted_s Time#in_time_zone
  Time#utc_to_local_returns_utc_offset_times
  Date.current Date.yesterday Date.tomorrow
  Date.beginning_of_week Date.end_of_week Date.beginning_of_month Date.end_of_month
  Date.beginning_of_year Date.end_of_year
  Date.beginning_of_week= Date.beginning_of_week_default Date.beginning_of_week_default=
  Date.find_beginning_of_week!
  Date#beginning_of_week Date#end_of_week Date#ago Date#since Date#beginning_of_day
  Date#midnight Date#at_midnight Date#at_beginning_of_day Date#end_of_day Date#at_end_of_day
  Date#all_day
  Date#today? Date#tomorrow? Date#yesterday? Date#next_day? Date#prev_day? Date#past? Date#future?
  Date#before? Date#after? Date#at_beginning_of_week Date#at_end_of_week Date#next_week
  Date#prev_week Date#last_week Date#next_weekday Date#days_to_week_start Date#all_week
  Date#in Date#middle_of_day Date#midday Date#noon Date#at_midday Date#at_noon
  Date#at_middle_of_day Date#to_fs Date#to_formatted_s Date#in_time_zone
  Date#readable_inspect Date#default_inspect
  DateTime.current DateTime.civil_from_format
  DateTime#in_time_zone DateTime#beginning_of_week DateTime#end_of_week
  DateTime#at_beginning_of_week DateTime#at_end_of_week DateTime#next_week DateTime#prev_week
  DateTime#last_week DateTime#next_weekday DateTime#all_week DateTime#localtime
  DateTime#getlocal DateTime#utc_to_local_returns_utc_offset_times
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

  # #670. `Date` is the odd one out of the three, and it is worth pinning as a three-way comparison
  # rather than a pair: on `Date` this whole family is `in_time_zone.xxx` and reads `Time.zone`, while
  # `Time` and `DateTime` compute it from the receiver. A class-wide annotation copied from either of
  # the other two onto `Date` is the mistake this catches.
  it "keeps Date impure where Time and DateTime are pure, across the in_time_zone-routed family" do
    %w[middle_of_day midday noon at_midday at_noon at_middle_of_day all_day in].each do |selector|
      expect(pure?("Date##{selector}")).to be(false), "expected Date##{selector} to carry no %a{pure}"
      expect(pure?("DateTime##{selector}")).to be(true), "expected DateTime##{selector} to read %a{pure}"
      expect(pure?("Time##{selector}")).to be(true), "expected Time##{selector} to read %a{pure}"
    end
  end

  # The week-start family goes the other way: it reads `Date.beginning_of_week` through a default
  # argument on ALL THREE receivers, so no class in the trio may claim it.
  it "keeps the week-start family impure on every receiver, including the at_-prefixed aliases" do
    %w[beginning_of_week end_of_week at_beginning_of_week at_end_of_week next_week prev_week
       last_week next_weekday all_week].each do |selector|
      %w[Date DateTime Time].each do |receiver|
        expect(pure?("#{receiver}##{selector}")).to be(false),
                                                    "expected #{receiver}##{selector} to carry no %a{pure}"
      end
    end
  end
end
