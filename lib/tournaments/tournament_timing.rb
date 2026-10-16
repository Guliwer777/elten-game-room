# encoding: UTF-8
require_relative 'local_registration_time'
require_relative 'strict_json'

module GameRoomTournaments
  # Dates control registration/start, not the sporting result. Version two
  # uses zero only for an explicitly manual date; it is never an invented
  # distant deadline. Existing dated publications keep their stored contract.
  module TournamentTiming
    module_function

    def schedule(row)
      StrictJson.parse(row.fetch('schedule_json'), max_nesting: 8)
    end

    def optional?(row)
      row['schema_version'] == 2
    end

    def positive(value)
      value if value && value > 0
    end

    def starts_at(row)
      return positive(schedule(row).fetch('starts_at')) if optional?(row)
      schedule(row).fetch('windows').map do |window|
        LocalRegistrationTime.convert_in_zone(window.fetch('date'), window.fetch('start'), timezone: row.fetch('timezone'))
      end.min
    end

    def deadline_at(row)
      return positive(schedule(row).fetch('deadline_at')) if optional?(row)
      schedule(row).fetch('windows').map do |window|
        LocalRegistrationTime.convert_in_zone(window.fetch('end_date'), window.fetch('end'), timezone: row.fetch('timezone'))
      end.max
    end

    def started?(row, now)
      start = starts_at(row)
      start && now >= start
    end

    def closes_at(row)
      return row.fetch('registration_closes_at') unless optional?(row)
      [positive(row.fetch('registration_closes_at')), starts_at(row)].compact.min
    end

    def registration_closed?(row, now)
      closing = closes_at(row)
      closing && now >= closing
    end

    def registration_open?(row, now)
      opening = optional?(row) ? positive(row.fetch('registration_opens_at')) : row.fetch('registration_opens_at')
      opening && now >= opening && !registration_closed?(row, now)
    end

    def validate!(row, value)
      data = Publication::Data
      unless value.is_a?(Hash) && value.keys.sort == %w[deadline_at starts_at windows] &&
          %w[starts_at deadline_at].all? { |key| data.integer?(value[key]) }
        raise Publication::Invalid, :invalid_schedule
      end
      opening, closing = row.values_at('registration_opens_at', 'registration_closes_at')
      raise Publication::Invalid, :invalid_registration_time unless data.integer?(opening) && data.integer?(closing)
      start = value['starts_at']
      raise Publication::Invalid, :invalid_registration_time if opening > 0 && closing > 0 && closing < opening
      raise Publication::Invalid, :registration_after_start if start > 0 && (opening > start || closing > start)
    end
  end
end
