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
      unless value.is_a?(Hash) && (value.keys - ['daily_hours']).sort == %w[deadline_at starts_at windows] &&
          %w[starts_at deadline_at].all? { |key| data.integer?(value[key]) } && value['windows'].is_a?(Array)
        raise Publication::Invalid, :invalid_schedule
      end
      opening, closing = row.values_at('registration_opens_at', 'registration_closes_at')
      raise Publication::Invalid, :invalid_registration_time unless data.integer?(opening) && data.integer?(closing)
      start = value['starts_at']
      raise Publication::Invalid, :invalid_registration_time if opening > 0 && closing > 0 && closing < opening
      raise Publication::Invalid, :registration_after_start if start > 0 && (opening > start || closing > start)
      validate_daily_hours!(value['daily_hours']) if value.key?('daily_hours')
      raise Publication::Invalid, :invalid_playing_hours if value['daily_hours'] && !value['windows'].empty?
    end

    # A fixed, explicit UTC offset is part of the publication, not the timezone
    # of whichever player's computer happens to check admission.
    def validate_daily_hours!(hours)
      valid=hours.is_a?(Hash) && hours.keys.sort==%w[end start utc_offset_minutes] &&
        %w[start end].all?{|key|hours[key].is_a?(String) && hours[key].match?(/\A(?:[01][0-9]|2[0-3]):[0-5][0-9]\z/)} &&
        hours['start']!=hours['end'] && hours['utc_offset_minutes'].is_a?(Integer) &&
        hours['utc_offset_minutes'].between?(-720,840) && hours['utc_offset_minutes']%15==0
      raise Publication::Invalid,:invalid_playing_hours unless valid
    end

    def daily_window(hours, now)
      validate_daily_hours!(hours)
      offset=hours.fetch('utc_offset_minutes')*60
      first,last=%w[start end].map{|key|hours.fetch(key).split(':').map(&:to_i).then{|h,m|h*3600+m*60}}
      day=((now+offset)/86400)*86400-offset
      opens=day+first
      closes=day+last
      if last<first
        closes+=86400
        if now<opens
          opens-=86400
          closes-=86400
        end
      end
      {'opens'=>opens,'closes'=>closes} if opens<=now && now<closes
    end

    def offset_label(minutes)
      format('UTC%s%02d:%02d',minutes<0 ? '-' : '+',minutes.abs/60,minutes.abs%60)
    end
  end
end
