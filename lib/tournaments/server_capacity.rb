require_relative 'league_plan'
require_relative 'group_plan'

module GameRoomTournaments
  # Validate the advertised capacity before anybody registers, using the same
  # pure planners as the real schedule. Never truncate an accepted tournament.
  module ServerCapacity
    MAX_MATCHES = 256
    module_function

    def validate!(registry:, game_id:, settings:)
      people = settings.fetch('participant_limit', 128)
      seats = settings.fetch('players_per_match')
      team = registry.build(game_id).team_size(settings.fetch('game_options'), player_count: seats) == 2
      units = team ? people / 2 : people
      per_match = team ? seats / 2 : seats
      raise Publication::Invalid, :invalid_participant_limit if units < per_match
      participants = Array.new(units) { |index| "player-#{index}" }
      count = case settings.fetch('format')
      when 'round_robin'
        LeaguePlan.build(participants: participants, players_per_match: per_match,
          pairing: settings.fetch('pairing'), rematch: settings.fetch('rematch')).size
      when 'groups_knockout'
        if units < 4
          units - 1
        else
          GroupPlan.build(participants: participants, players_per_match: per_match,
            pairing: settings.fetch('pairing'), rematch: settings.fetch('rematch'),
            group_count: settings['group_count'], places_per_group: settings['places_per_group'],
            advancement: settings['group_advancement']).fetch('match_count')
        end
      when 'knockout' then units
      else raise Publication::Invalid, :unsupported_format
      end
      raise Publication::Invalid, :server_match_capacity if count > MAX_MATCHES
      true
    rescue LeaguePlan::Invalid => error
      raise Publication::Invalid, error.code.to_s.include?('too_many') ? :server_match_capacity : error.code
    end
  end
end
