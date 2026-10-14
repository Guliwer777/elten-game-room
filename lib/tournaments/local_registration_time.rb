# encoding: UTF-8
# frozen_string_literal: true
require 'date'
require_relative '../game_room_localization'
require_relative '../game_content'

module GameRoomTournaments
  # Cywilny czas systemowy wyłącznie jawnego lokalnego sandboxa, nie IANA
  # ani czas serwera. Nie zmienia ENV['TZ'], systemu ani globalnej klasy Time.
  module LocalRegistrationTime
    class Invalid < ArgumentError
      using GameRoomLocalization::Translations
      attr_reader :code
      def initialize(code)
        @code = code
        super(code.to_s)
      end

      # Dopiero odbiorca na UI tłumaczy błąd; sama konwersja jest czysta.
      def message
        text = case @code
        when :invalid_date
          _("Enter a valid date in YYYY-MM-DD format (year 0001-9999).")
        when :invalid_time
          _("Enter a valid time in HH:MM format.")
        when :nonexistent_time
          _("This time does not exist in the local system time zone. Choose another time.")
        when :ambiguous_time
          _("This time occurs twice in the local system time zone. Choose another time.")
        when :invalid_timestamp
          _("This date is before the supported Unix time range. Choose a later date.")
        else
          _("This platform cannot safely convert the local time. Choose another date or time.")
        end
        GameRoomContent.utf8(text)
      end
    end

    module_function

    def convert(date, time, time_adapter: Time)
      resolve(civil_parts(date, time), time_adapter)
    end

    # Explicit UTC publications have the same instant on every computer.
    # This is not a resolver for arbitrary IANA zone identifiers.
    def convert_utc(date, time)
      parts = civil_parts(date, time)
      instant = Time.utc(*parts)
      raise Invalid, :unsupported_time unless components(instant) == parts
      seconds = instant.to_i
      raise Invalid, :invalid_timestamp unless seconds.between?(0, (2**63) - 1)
      seconds
    rescue ArgumentError, RangeError, NotImplementedError => error
      raise if error.is_a?(Invalid)
      raise Invalid, :unsupported_time
    end

    def convert_in_zone(date, time, timezone:)
      case timezone
      when 'UTC' then convert_utc(date, time)
      when 'local_test:system' then convert(date, time)
      else raise Invalid, :unsupported_time
      end
    end

    def utc_window(opens, closes)
      unless [opens, closes].all? { |value| value.is_a?(Integer) && value.between?(0, (2**63) - 1) } && closes > opens
        raise Invalid, :invalid_timestamp
      end
      first, last = [opens, closes].map { |value| Time.at(value).utc }
      raise Invalid, :unsupported_time unless [first, last].all? { |value| value.sec.zero? && value.year.between?(1, 9999) }
      {'date' => first.strftime('%Y-%m-%d'), 'start' => first.strftime('%H:%M'),
        'end_date' => last.strftime('%Y-%m-%d'), 'end' => last.strftime('%H:%M')}
    end

    def civil_parts(date, time)
      raise Invalid, :invalid_date unless text?(date) && date.match?(/\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/)
      raise Invalid, :invalid_time unless text?(time) && time.match?(/\A[0-9]{2}:[0-9]{2}\z/)
      year, month, day = date.split('-').map(&:to_i)
      hour, minute = time.split(':').map(&:to_i)
      unless year.between?(1, 9999) && Date.valid_date?(year, month, day, Date::GREGORIAN)
        raise Invalid, :invalid_date
      end
      raise Invalid, :invalid_time unless hour.between?(0, 23) && minute.between?(0, 59)
      [year, month, day, hour, minute, 0]
    end
    private_class_method :civil_parts

    # Adapter jest tylko szwem izolowanych testów; aplikacja używa Time.local.
    # Nie zgadujemy wyboru Time.local w powtórzonej godzinie. Zbieramy offsety
    # co godzinę w obrębie ±48 h i sprawdzamy każdy kandydat pełnym roundtripem.
    def resolve(parts, adapter)
      local = adapter.local(*parts)
      raise Invalid, :nonexistent_time unless components(local) == parts
      civil = adapter.utc(*parts).to_i
      offsets = (-48..48).map { |hour| adapter.at(local.to_i + hour * 3600).getlocal.utc_offset }
      offsets << local.utc_offset
      unless offsets.all? { |offset| offset.is_a?(Integer) && offset.abs < 86_400 }
        raise Invalid, :unsupported_time
      end
      candidates = offsets.uniq.filter_map do |offset|
        seconds = civil - offset
        roundtrip = adapter.at(seconds).getlocal
        seconds if components(roundtrip) == parts && roundtrip.utc_offset == offset && roundtrip.to_i == seconds
      end.uniq
      raise Invalid, :ambiguous_time if candidates.length > 1
      unless candidates.length == 1 && candidates.first == local.to_i
        raise Invalid, :unsupported_time
      end
      result = candidates.first
      raise Invalid, :invalid_timestamp unless result.between?(0, (2**63) - 1)
      result
    rescue Invalid
      raise
    rescue ArgumentError, RangeError, NotImplementedError
      # Tylko ograniczenia natywnej reprezentacji czasu, nie NoMethodError.
      raise Invalid, :unsupported_time
    end
    private_class_method :resolve

    def components(time)
      [time.year, time.month, time.day, time.hour, time.min, time.sec]
    end
    private_class_method :components

    def text?(value)
      value.is_a?(String) && value.valid_encoding? && value.encoding.ascii_compatible? && value.ascii_only?
    end
    private_class_method :text?
  end
end
