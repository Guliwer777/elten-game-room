require_relative 'group_schedule'
require_relative 'group_qualification'
require_relative 'cross_group_seeding'
require_relative 'compact_group_seeding'

module GameRoomTournaments
  # Projects verified execution receipts into separate group tables. Scores
  # are never compared across groups with different opponents.
  module GroupStandings
    module_function
    def calculate(candidate:, units:, results:, unit_key:, players_per_match:)
      GroupSchedule.validate!(candidate, units: units, unit_key: unit_key, players_per_match: players_per_match)
      by_id = candidate['matches'].to_h do |match|
        [match['match_id'], {'id' => JSON.generate([match['match_id'], match['leg']]),
          'participants' => match.fetch(unit_key)}]
      end
      Standings.calculate(units: units, results: results)
      valid_ids = by_id.values.map { |fixture| fixture['id'] }
      unless results.all? { |result| valid_ids.include?(result['id']) }
        raise Publication::Invalid, :sandbox_corrupt
      end
      normalized = results.to_h { |result| [result['id'], result] }
      grouped_results = []
      groups = candidate['groups'].map do |group|
        fixtures = group['matches'].map { |id| by_id.fetch(id) }
        own = fixtures.filter_map do |fixture|
          result = normalized[fixture['id']]
          next unless result
          unless result['participants'].sort == fixture['participants'].sort
            raise Publication::Invalid, :sandbox_corrupt
          end
          result.merge('participants' => fixture['participants'])
        end
        grouped_results << own
        group.slice('id', 'units', 'places').merge('qualification' => GroupQualification.calculate(
          units: group['units'], matches: fixtures, results: own, places: group['places']))
      end
      states = groups.map { |group| group['qualification']['state'] }
      state = if states.include?('awaiting_results')
        'awaiting_results'
      elsif states.include?('tie_requires_resolution')
        'tie_requires_resolution'
      else
        'awaiting_seeding'
      end
      cross = nil
      if GroupAdvancement.automatic?(candidate['group_advancement']) && state == 'awaiting_seeding'
        cross = candidate['group_advancement'] == GroupAdvancement::COMPACT ?
          CompactGroupSeeding.build(groups: groups, results_by_group: grouped_results) : CrossGroupSeeding.build(groups: groups)
        state = cross['state'] == 'ready' ? 'ready_knockout' : 'seeding_tie_requires_resolution'
      end
      {'group_state' => state, 'groups' => groups, 'cross_seeding' => cross,
        'group_results' => grouped_results,
        'qualified' => cross && cross['state'] == 'ready' ? cross['seeds'] : groups.flat_map { |group| group['qualification']['qualified'] },
        'standings' => groups.flat_map do |group|
          group['qualification']['standings'].map { |row| row.merge('group' => group['id']) }
        end}
    end
  end
end
