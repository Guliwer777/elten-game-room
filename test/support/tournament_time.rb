# frozen_string_literal: true

module TournamentTimeSupport
  # Deterministic 2026 DST rules, independent of Windows and ENV['TZ'].
  # Both choices of the repeated autumn hour exercise the real resolver.
  class SeasonalTime
    Stamp = Struct.new(:local_time) do
      def getlocal; local_time; end
    end
    attr_reader :local_calls

    def initialize(preferred = 7200)
      @preferred, @local_calls = preferred, []
      @spring = Time.utc(2026, 3, 29, 1, 0, 0).to_i
      @autumn = Time.utc(2026, 10, 25, 1, 0, 0).to_i
    end

    def utc(*parts); Time.utc(*parts); end

    def at(seconds)
      offset = seconds >= @spring && seconds < @autumn ? 7200 : 3600
      Stamp.new(Time.at(seconds).getlocal(offset))
    end

    def local(*parts)
      @local_calls << parts
      civil = Time.utc(*parts).to_i
      options = [@preferred, 10_800 - @preferred].map { |offset| at(civil - offset).getlocal }
      options.find { |time| time.to_a.values_at(5, 4, 3, 2, 1, 0) == parts } || at(civil - 3600).getlocal
    end
  end

  # Test processes are isolated. Replace only the resolver's existing clock
  # seam for this block, restoring it even when the scenario raises.
  def self.with_adapter(adapter)
    resolver = GameRoomTournaments::LocalRegistrationTime
    original = resolver.method(:convert)
    resolver.define_singleton_method(:convert) do |date, time, **options|
      original.call(date, time, **options.merge(time_adapter: adapter))
    end
    yield
  ensure
    resolver.define_singleton_method(:convert, original) if original
  end
end
