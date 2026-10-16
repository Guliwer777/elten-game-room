require_relative 'standings_ranking'
require_relative 'group_standings'
require_relative 'knockout_standings'
module GameRoomTournaments
  class LocalIndividualStandings
    Data = Publication::Data
    def self.build(record:, executions:)
      intent = record['preview']['intent_id']
      matches = record['evidence']['plan']['matches']
      planned = matches.to_h { |match| [[match['match_id'], match['leg']], match] }
      results = {}
      executions.select { |row| row['record_intent'] == intent && row['result'] }.each do |execution|
        receipt = execution['result']
        key = receipt.values_at('match_id', 'leg')
        match = planned[key]
        summary = receipt['summary']
        unless match && !results.key?(key) && receipt['record_intent'] == intent &&
            summary.is_a?(Hash) && summary['participants'] == match['players'].map { |p| p['account'] }.sort
          raise Publication::Invalid, :sandbox_corrupt
        end
        results[key] = receipt
      end
      normalized = results.map do |key, receipt|
        receipt['summary'].slice('participants', 'winners', 'scores', 'score_order').merge('id' => JSON.generate(key))
      end
      units = record['evidence']['source']['roster'].map { |p| p['account'] }
      group_summary = {}
      candidate = record['preview']['source']['candidate']
      if candidate['format'] == 'knockout'
        group_summary = KnockoutStandings.calculate(candidate: candidate, units: units, results: normalized, unit_key: 'players')
        table = group_summary['standings']
      elsif candidate['format'] == 'groups_knockout'
        group_summary = GroupStandings.calculate(candidate: candidate, units: units, results: normalized,
          unit_key: 'players', players_per_match: candidate['players_per_match'])
        table = group_summary['standings']
      else
        table = StandingsRanking.calculate(units: units, results: normalized, points: Standings::MATCH_POINTS,
          criteria: StandingsRanking::CRITERIA)
      end
      Data.freeze_tree(Data.copy(group_summary.merge('total' => planned.size, 'completed' => results.size,
        'remaining' => planned.size - results.size, 'complete' => !planned.empty? && results.size == planned.size,
        'standings' => table, 'results' => results.values.sort_by { |r| [r['match_id'], r['leg']] }.map do |receipt|
          receipt.slice('match_id', 'leg', 'summary', 'kind', 'reason')
        end), max_bytes: 262_144, max_nodes: 16_384, max_depth: 12))
    end
  end
end
