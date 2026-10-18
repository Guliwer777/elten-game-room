require_relative 'local_registration_time'

module GameRoomTournaments
  module ServerMatchWindow
    module_function
    def current(candidate, now)
      raise Publication::Invalid, :invalid_clock unless Publication::Data.integer?(now)
      if candidate.key?('starts_at')
        start=candidate['starts_at']
        raise Publication::Invalid,:tournament_not_started unless Publication::Data.integer?(start,1) && start<=now
        if candidate['daily_hours']
          window=TournamentTiming.daily_window(candidate['daily_hours'],now)
          raise Publication::Invalid,:outside_window unless window
          return window.merge('opens'=>[window['opens'],start].max)
        end
        return {'opens'=>start,'closes'=>nil} if candidate.fetch('windows').empty?
      end
      windows=candidate.fetch('windows').map do |civil|
        {'opens'=>LocalRegistrationTime.convert_in_zone(civil.fetch('date'),civil.fetch('start'),timezone:candidate.fetch('timezone')),
          'closes'=>LocalRegistrationTime.convert_in_zone(civil.fetch('end_date'),civil.fetch('end'),timezone:candidate.fetch('timezone'))}
      end
      windows.find{|window|window['opens']<=now && now<window['closes']} || (raise Publication::Invalid,:outside_window)
    end
  end
end
