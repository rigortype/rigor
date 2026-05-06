# frozen_string_literal: true

require_relative "lib/units"

# Run with the plugin from inside this directory:
#
#   RUBYLIB=$PWD/../lib bundle exec rigor check demo.rb
#
# Each local assignment with an inferred dimension surfaces as
# an `info` diagnostic naming the dimension; each `.in_<unit>`
# query emits a second `info` diagnostic naming the conversion.

# ==========================================
# 1. Distance and Time
# ==========================================
distance = 100.kilometers
time     = 2.hours

# Same-dimension arithmetic.
total_distance = 10.kilometers + 500.meters

# ==========================================
# 2. Speed
# ==========================================

# Distance / Time = Speed.
speed = distance / time

puts speed.in_kilometers_per_hour # => 50.0
puts speed.in_meters_per_second   # => ≈ 13.89

# Chained constructor — Distance.per_hour collapses to Speed.
speed_limit = 60.kilometers.per_hour
wind_speed  = 15.meters.per_second

# Same-dimension comparison stays in `bool`.
if speed <= speed_limit
  puts "within the limit."
else
  puts "over the limit."
end

# ==========================================
# 3. Acceleration
# ==========================================

# 0 km/h → 100 km/h in 5 seconds.
initial_speed = 0.kilometers.per_hour
final_speed   = 100.kilometers.per_hour
duration      = 5.seconds

# (Speed - Speed) / Time = Acceleration.
car_acceleration = (final_speed - initial_speed) / duration

puts car_acceleration.in_meters_per_second_squared # => ≈ 5.55

# Direct constructor for gravity.
gravity = 9.8.meters.per_second_squared

# Free-fall final speed: Acceleration * Time = Speed.
fall_time = 3.seconds
velocity_after_fall = gravity * fall_time

puts velocity_after_fall.in_meters_per_second # => 29.4

# Suppress runtime "unused variable" warnings for the demo's
# read-only locals; the static analysis above is the point.
_ = [distance, total_distance, wind_speed]
