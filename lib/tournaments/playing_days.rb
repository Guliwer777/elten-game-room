require_relative 'local_registration_time'
require_relative 'publication'
module GameRoomTournaments
  # Resolve each civil day separately; a local day is not always 86400 seconds.
  module PlayingDays
    module_function
    def build(mode:,first_date:,last_date:,opens:,closes:,converter:LocalRegistrationTime.method(:convert))
      raise Publication::Invalid,:invalid_playing_days unless %w[single daily].include?(mode)
      first=Date.iso8601(first_date)
      last=mode=='single' ? first : Date.iso8601(last_date)
      raise Publication::Invalid,:invalid_playing_days unless last>=first && (last-first).to_i<256
      (first..last).map do |date|
        day=date.strftime('%Y-%m-%d')
        start=converter.call(day,opens)
        ending=converter.call(day,closes)
        raise Publication::Invalid,:invalid_playing_hours unless closes>opens && ending>start
        LocalRegistrationTime.utc_window(start,ending)
      end
    rescue Date::Error
      raise Publication::Invalid,:invalid_playing_days
    end
    def local_intervals(windows,timezone:)
      windows.map do |window|
        [LocalRegistrationTime.convert_in_zone(window['date'],window['start'],timezone:timezone),
          LocalRegistrationTime.convert_in_zone(window['end_date'] || window['date'],window['end'],timezone:timezone)].map{|stamp|Time.at(stamp).getlocal}
      end
    end
    def mode(intervals)
      daily=intervals.all?{|first,last|first.strftime('%Y-%m-%d')==last.strftime('%Y-%m-%d') && last>first}
      return 'preserve' unless daily && !intervals.empty?
      return 'single' if intervals.size==1
      dates=intervals.map{|first,_|Date.new(first.year,first.month,first.day)}
      hours=intervals.map{|first,last|[first.strftime('%H:%M'),last.strftime('%H:%M')]}.uniq
      hours.size==1 && dates.each_cons(2).all?{|first,last|last==first+1} ? 'daily' : 'preserve'
    end
  end
end
