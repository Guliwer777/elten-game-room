# encoding: UTF-8
require_relative 'standings_ranking'
require_relative 'group_standings'
require_relative 'knockout_standings'
require_relative 'game_result'

module GameRoomTournaments
  # Public summary only; game history is verified by execution storage first.
  class LocalFixedTeamStandings
    Data = Publication::Data
    def self.build(record:, executions:)
      intent = record['preview']['intent_id']
      matches = record['evidence']['plan']['matches']
      planned = matches.to_h { |match| [[match['match_id'], match['leg']], match] }
      results = {}
      policy = record['evidence']['source']['result_policy']
      modern = GameResult::RESULT_POLICIES.include?(policy)
      executions.select { |row| row['record_intent'] == intent && row['result'] }.each do |execution|
        receipt = execution['result']
        key = [receipt['match_id'], receipt['leg']]
        match = planned[key]
        summary = receipt['summary']
        teams = match && match['players'].map { |person| person['team'] }.uniq.sort
        valid_order = if summary.is_a?(Hash)
          ordered = receipt['kind'] != 'forfeit' && GameResult::ORDERED_POLICIES.include?(policy) &&
            !(policy == GameResult::CURRENT_RESULT_POLICY && summary['scores'].nil?)
          ordered ? %w[higher lower].include?(summary['score_order']) : !summary.key?('score_order')
        end
        valid_summary = if !match
          false
        elsif modern || receipt['kind'] == 'forfeit'
          summary.is_a?(Hash) && summary['participants'] == teams && summary['winners'].is_a?(Array) &&
            valid_order &&
            summary['winners'].uniq == summary['winners'] && summary['winners'].all? { |winner| teams.include?(winner) } &&
            [true, false].include?(summary['draw']) && (summary['draw'] ? summary['winners'].empty? : summary['winners'].any?) &&
            (summary['scores'].nil? || (summary['scores'].is_a?(Hash) && summary['scores'].keys.sort == teams &&
              summary['scores'].values.all? { |score| score.is_a?(Integer) || (score.is_a?(Float) && score.finite?) }))
        else
          summary.is_a?(Hash) && summary['scores'].is_a?(Hash) && summary['scores'].keys.sort == teams &&
            teams.include?(summary['winner']) && summary['scores'].values.all? { |score| score.is_a?(Integer) }
        end
        unless match && !results.key?(key) && receipt['record_intent'] == intent && valid_summary
          raise Publication::Invalid, :sandbox_corrupt
        end
        results[key] = receipt
      end
      teams = record['evidence']['source']['membership']['units'].map { |unit| unit['unit_id'] }
      normalized = results.map do |key, receipt|
        summary = receipt['summary']
        if modern || receipt['kind'] == 'forfeit'
          summary.slice('participants', 'winners', 'scores', 'score_order', 'places').merge('id' => JSON.generate(key))
        else
          {'id' => JSON.generate(key), 'participants' => summary['scores'].keys,
            'winners' => [summary['winner']], 'scores' => summary['scores']}
        end
      end
      group_summary = {}
      candidate = record['preview']['source']['candidate']
      if candidate['format'] == 'knockout'
        group_summary = KnockoutStandings.calculate(candidate: candidate, units: teams, results: normalized, unit_key: 'unit_ids')
        ranked = group_summary['standings']
      elsif candidate['format'] == 'groups_knockout'
        group_summary = GroupStandings.calculate(candidate: candidate, units: teams, results: normalized,
          unit_key: 'unit_ids', players_per_match: 2)
        ranked = group_summary['standings']
      else
        ranked = StandingsRanking.calculate(units: teams, results: normalized, points: Standings::MATCH_POINTS,
          criteria: StandingsRanking::CRITERIA)
      end
      table = ranked.map do |row|
        row.slice('group', 'score_order').merge('team' => row['unit'], 'place' => row['place'], 'played' => row['played'], 'wins' => row['wins'], 'losses' => row['losses'],
          'points' => row['points'], 'draws' => row['draws'],
          'score_for' => row['score_for'], 'score_against' => row['score_against'])
      end
      Data.freeze_tree(Data.copy(group_summary.merge('total' => planned.size, 'completed' => results.size,
        'remaining' => planned.size - results.size, 'complete' => !planned.empty? && results.size == planned.size,
        'standings' => table, 'results' => results.values.sort_by { |r| [r['match_id'], r['leg']] }.map do |receipt|
          receipt.slice('match_id', 'leg', 'summary', 'kind', 'reason')
        end), max_bytes: 262_144, max_nodes: 16_384, max_depth: 12))
    end
  end
end
