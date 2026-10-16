require_relative 'standings_ranking'

module GameRoomTournaments
  # Pure projection of an accepted group plan and verified results. Unit IDs
  # may identify individuals or indivisible teams; fixtures may be multiplayer.
  # This is not permission to dispatch a knockout match.
  class GroupQualification
    def self.calculate(units:, matches:, results:, places:)
      unless matches.is_a?(Array) && matches.size.between?(1, 256) &&
          results.is_a?(Array) && results.size <= 256 && places.is_a?(Integer) &&
          units.is_a?(Array) && places.between?(1, units.size)
        raise Publication::Invalid, :invalid_group_plan
      end
      # Validate the roster and fixture shape through the existing arithmetic
      # contract, without interpreting missing results as draws.
      fixtures = matches.map do |match|
        unless match.is_a?(Hash) && [%w[id participants], %w[id leg participants]].include?(match.keys.sort) &&
            (!match.key?('leg') || [1, 2].include?(match['leg']))
          raise Publication::Invalid, :invalid_group_plan
        end
        match.slice('id', 'participants').merge('winners' => [])
      end
      Standings.calculate(units: units, results: fixtures)
      unless (units - matches.flat_map { |match| match['participants'] }).empty?
        raise Publication::Invalid, :invalid_group_plan
      end
      table = StandingsRanking.calculate(units: units, results: results,
        points: Standings::MATCH_POINTS, criteria: StandingsRanking::CRITERIA)
      index = matches.to_h { |match| [match['id'], match['participants']] }
      unless results.all? { |result| index[result['id']] == result['participants'] }
        raise Publication::Invalid, :result_outside_group_plan
      end
      missing = matches.map { |match| match['id'] } - results.map { |result| result['id'] }
      from_table(table: table, places: places, missing: missing)
    end

    def self.from_table(table:, places:, missing: [])
      qualified, unresolved = [], []
      state = 'awaiting_results'
      if missing.empty?
        state = 'ready'
        table.group_by { |row| row['place'] }.each_value do |tied|
          next if qualified.size >= places
          if qualified.size + tied.size > places
            unresolved = tied.map { |row| row['unit'] }
            state = 'tie_requires_resolution'
            break
          end
          qualified.concat(tied.map { |row| row['unit'] })
        end
      end
      Publication::Data.freeze_tree(Publication::Data.copy({
        'state' => state, 'standings' => table, 'missing_matches' => missing,
        'qualified' => qualified, 'unresolved' => unresolved,
        'places_remaining' => places - qualified.size
      }, max_bytes: 524_288, max_nodes: 32_768, max_depth: 10))
    end
  end
end
