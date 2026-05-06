# frozen_string_literal: true

# Tiny units-of-measure runtime the rigor-units plugin types
# statically. The classes are minimal — just enough to make
# the demo executable under MRI. The plugin's value is what
# `rigor check` says about the call sites, not what the
# runtime does internally.

# Internal storage is the SI base unit: meters for distance,
# seconds for time, m/s for speed, m/s² for acceleration.

class Distance
  include Comparable
  attr_reader :meters

  def initialize(meters)
    @meters = meters.to_f
  end

  def +(other) = Distance.new(meters + other.meters)
  def -(other) = Distance.new(meters - other.meters)
  def <=>(other) = meters <=> other.meters

  def /(other)
    case other
    when Time then Speed.new(meters / other.seconds)
    end
  end

  def per_hour = Speed.new(meters / 3600.0)
  def per_minute = Speed.new(meters / 60.0)
  def per_second = Speed.new(meters)
  def per_second_squared = Acceleration.new(meters)

  def in_meters = meters
  def in_kilometers = meters / 1000.0
  def in_miles = meters / 1609.344
  def in_feet = meters / 0.3048
end

class Time
  include Comparable
  attr_reader :seconds

  def initialize(seconds)
    @seconds = seconds.to_f
  end

  def +(other) = Time.new(seconds + other.seconds)
  def -(other) = Time.new(seconds - other.seconds)
  def <=>(other) = seconds <=> other.seconds

  def in_seconds = seconds
  def in_minutes = seconds / 60.0
  def in_hours = seconds / 3600.0
end

class Speed
  include Comparable
  attr_reader :meters_per_second

  def initialize(meters_per_second)
    @meters_per_second = meters_per_second.to_f
  end

  def +(other) = Speed.new(meters_per_second + other.meters_per_second)
  def -(other) = Speed.new(meters_per_second - other.meters_per_second)
  def <=>(other) = meters_per_second <=> other.meters_per_second

  def *(other)
    case other
    when Time then Distance.new(meters_per_second * other.seconds)
    end
  end

  def /(other)
    case other
    when Time then Acceleration.new(meters_per_second / other.seconds)
    end
  end

  def in_meters_per_second = meters_per_second
  def in_kilometers_per_hour = meters_per_second * 3.6
  def in_miles_per_hour = meters_per_second * 2.236936
end

class Acceleration
  include Comparable
  attr_reader :meters_per_second_squared

  def initialize(meters_per_second_squared)
    @meters_per_second_squared = meters_per_second_squared.to_f
  end

  def *(other)
    case other
    when Time then Speed.new(meters_per_second_squared * other.seconds)
    end
  end

  def <=>(other) = meters_per_second_squared <=> other.meters_per_second_squared

  def in_meters_per_second_squared = meters_per_second_squared
  def in_kilometers_per_hour_squared = meters_per_second_squared * 12_960.0
end

class Numeric
  def kilometers = Distance.new(self * 1000.0)
  def meters = Distance.new(to_f)
  def miles = Distance.new(self * 1609.344)
  def feet = Distance.new(self * 0.3048)
  def seconds = Time.new(to_f)
  def minutes = Time.new(self * 60.0)
  def hours = Time.new(self * 3600.0)
end
