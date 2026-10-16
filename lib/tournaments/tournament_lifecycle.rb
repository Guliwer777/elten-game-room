require_relative 'publication'
require_relative 'local_registration_time'
module GameRoomTournaments
  module TournamentLifecycle
    module_function
    def classify(publication, now:)
      raise Publication::Invalid, :invalid_clock unless Publication::Data.integer?(now)
      return {state: :completed, archived: false}.freeze if publication['sporting_completed']==true
      if TournamentTiming.optional?(publication)
        state=if TournamentTiming.started?(publication,now) then :running
        elsif TournamentTiming.registration_closed?(publication,now) then :waiting
        elsif TournamentTiming.registration_open?(publication,now) then :registration
        else :soon
        end
        deadline=TournamentTiming.deadline_at(publication)
        return {state:state,archived:false,overdue:!!(deadline && now>=deadline)}.freeze
      end
      converter = case publication['timezone']
      when 'UTC' then :convert_utc
      when 'local_test:system' then :convert
      else return {state: :unknown, archived: false}.freeze
      end
      windows = StrictJson.parse(publication.fetch('schedule_json'), max_nesting: 8).fetch('windows')
      first = windows.map { |w| LocalRegistrationTime.public_send(converter, w['date'], w['start']) }.min
      last = windows.map { |w| LocalRegistrationTime.public_send(converter, w['end_date'], w['end']) }.max
      state = if now >= last then :ended
      elsif now >= first then :running
      elsif now >= publication.fetch('registration_closes_at') then :waiting
      elsif now >= publication.fetch('registration_opens_at') then :registration
      else :soon
      end
      {state: state, archived: false}.freeze
    end
    def ending_at(publication)
      return publication['sporting_completed_at'] if publication['sporting_completed']==true && Publication::Data.integer?(publication['sporting_completed_at'])
      return TournamentTiming.deadline_at(publication) if TournamentTiming.optional?(publication)
      converter=publication['timezone']=='UTC' ? :convert_utc : :convert
      windows=StrictJson.parse(publication.fetch('schedule_json'),max_nesting:8).fetch('windows')
      windows.map{|window|LocalRegistrationTime.public_send(converter,window['end_date'],window['end'])}.max
    end
    def next_change(publication,now:)
      return nil if publication['sporting_completed']==true
      if TournamentTiming.optional?(publication)
        return [publication['expires_at'],publication['registration_opens_at'],TournamentTiming.closes_at(publication),TournamentTiming.starts_at(publication),TournamentTiming.deadline_at(publication)].compact.select{|time|time>now}.min
      end
      return nil unless ['UTC','local_test:system'].include?(publication['timezone'])
      converter=publication['timezone']=='UTC' ? :convert_utc : :convert
      windows=StrictJson.parse(publication.fetch('schedule_json'),max_nesting:8).fetch('windows')
      first=windows.map{|window|LocalRegistrationTime.public_send(converter,window['date'],window['start'])}.min
      [publication['expires_at'],publication['registration_opens_at'],publication['registration_closes_at'],first,ending_at(publication)].compact.select{|time|time>now}.min
    end
  end
end
