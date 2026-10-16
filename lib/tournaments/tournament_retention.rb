require_relative 'registration_projection'

module GameRoomTournaments
  # Deterministic expiry from server evidence. There is no new heartbeat,
  # housekeeping write, local renewal flag or dependence on organizer uptime.
  module TournamentRetention
    BEFORE_START = 14 * 86_400
    AFTER_START = 30 * 86_400
    module_function

    def deadline(publication, activity)
      start = TournamentTiming.starts_at(publication)
      return [activity, start].max + AFTER_START if start
      opening = publication.fetch('registration_opens_at')
      [activity, opening].max + BEFORE_START
    end

    def evaluate(history, now:, progress: [], completed_at: nil)
      raise Publication::Invalid, :invalid_clock unless Publication::Data.integer?(now)
      row = history.fetch(:publication)
      last = row.fetch('__insertion_time')
      expires = deadline(row, last)
      events = history.fetch(:events) + progress.map { |time| {time: time, id: 0} }
      events << {time: completed_at, id: 0, completed: true} if completed_at
      events.sort_by { |event| [event.fetch(:time), event.fetch(:id)] }.each do |event|
        time = event.fetch(:time)
        raise Publication::Invalid, :invalid_retention_timestamp unless Publication::Data.integer?(time)
        next if time < last || time > now
        # Later writes, including an old client's late result or amendment,
        # must not bring back a tournament which already expired.
        break if time >= expires
        return {expired: false, completed: true, expires_at: nil}.freeze if event[:completed]
        row = event[:publication] || row
        last = time
        expires = deadline(row, last)
      end
      {expired: now >= expires, completed: false, expires_at: expires}.freeze
    end
  end
end
