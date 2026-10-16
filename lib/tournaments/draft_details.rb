# encoding: UTF-8
require "date"

module GameRoomTournaments
  # Wyłącznie dane lokalnego szkicu, bez potwierdzania kont i rejestracji.
  module DraftDetails
    DEFAULTS = {"participants" => [].freeze, "windows" => [].freeze,
      "players_per_match" => nil, "pairing" => nil,
      "group_count" => nil, "places_per_group" => nil, "group_advancement" => nil}.freeze

    class Invalid < ArgumentError
      attr_reader :code

      def initialize(code)
        @code = code
        super(code.to_s)
      end
    end

    def self.validate!(attributes)
      validate_participants(attributes.fetch("participants", DEFAULTS["participants"]))
      validate_windows(attributes.fetch("windows", DEFAULTS["windows"]))
      players = attributes.fetch("players_per_match", DEFAULTS["players_per_match"])
      unless players.nil? || (players.is_a?(Integer) && players.between?(2, 8))
        raise Invalid, :invalid_players_per_match
      end
      pairing = attributes.fetch("pairing", DEFAULTS["pairing"])
      unless pairing.nil? || (pairing.is_a?(String) && ["all_combinations", "balanced_cycle"].include?(pairing))
        raise Invalid, :invalid_pairing
      end
      {'group_count' => (2..128), 'places_per_group' => (1..255)}.each do |key, range|
        value = attributes.fetch(key, nil)
        unless value.nil? || (value.is_a?(Integer) && range.cover?(value))
          raise Invalid, :invalid_group_configuration
        end
      end
      unless [nil, 'automatic_cross_groups_v1', 'automatic_compact_groups_v2'].include?(attributes.fetch('group_advancement', nil))
        raise Invalid, :invalid_group_configuration
      end
      true
    end

    def self.text?(value, maximum_bytes)
      value.is_a?(String) && value.bytesize <= maximum_bytes && value.valid_encoding? &&
        value.encoding.ascii_compatible? && (value.encoding == Encoding::UTF_8 || value.ascii_only?)
    end
    private_class_method :text?

    def self.validate_participants(participants)
      raise Invalid, :invalid_participants unless participants.is_a?(Array) && participants.size <= 256
      seen = {}
      participants.each do |name|
        unless text?(name, 256) && name.length.between?(1, 64) &&
            !name.match?(/[[:cntrl:]\u2028\u2029]/) && !name.match?(/\A[[:space:]]|[[:space:]]\z/)
          raise Invalid, :invalid_participants
        end
        key = name.downcase
        raise Invalid, :invalid_participants if seen[key]
        seen[key] = true
      end
    end
    private_class_method :validate_participants

    WINDOW_FIELDS = %w[date start end_date end].freeze

    def self.validate_windows(windows)
      raise Invalid, :invalid_windows unless windows.is_a?(Array) && windows.size <= 366
      intervals = windows.map do |window|
        unless window.is_a?(Hash) && window.size == WINDOW_FIELDS.size &&
            WINDOW_FIELDS.all? { |key| window.key?(key) }
          raise Invalid, :invalid_windows
        end
        first = civil_minutes(window["date"], window["start"])
        last = civil_minutes(window["end_date"], window["end"])
        raise Invalid, :invalid_windows unless last > first
        [first, last]
      end
      # Sortowana jest tylko projekcja, nie tablica przekazana przez użytkownika.
      intervals.sort_by!(&:first)
      intervals.each_cons(2) do |previous, following|
        raise Invalid, :invalid_windows if following.first < previous.last
      end
    end
    private_class_method :validate_windows

    def self.civil_minutes(date, time)
      unless text?(date, 10) && date.match?(/\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/) &&
          text?(time, 5) && time.match?(/\A(?:[01][0-9]|2[0-3]):[0-5][0-9]\z/)
        raise Invalid, :invalid_windows
      end
      year, month, day = date.split("-").map(&:to_i)
      raise Invalid, :invalid_windows unless year.between?(1, 9999) && Date.valid_date?(year, month, day, Date::GREGORIAN)
      # Cywilne minuty; bez Time, strefy systemowej, DST i konwersji do UTC.
      Date.new(year, month, day, Date::GREGORIAN).jd * 1440 + time[0, 2].to_i * 60 + time[3, 2].to_i
    end
    private_class_method :civil_minutes
  end
end
