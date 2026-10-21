require_relative 'knockout_schedule'
require_relative 'knockout_series'

module GameRoomTournaments
  module KnockoutStandings
    module_function
    def calculate(candidate:, units:, results:, unit_key:)
      metadata = candidate.fetch('knockout')
      schedule, expected = KnockoutSchedule.matches(metadata: metadata, generation: candidate['roster_generation'], membership: candidate['membership'])
      unless candidate['schedule_id'] == schedule && candidate['matches'].eql?(expected)
        raise Publication::Invalid, :sandbox_corrupt
      end
      Standings.calculate(units: units, results: results)
      plan = metadata.key?('series') ? KnockoutWinSeries.from_metadata(metadata) : metadata.key?('qualification') ? GroupTiebreak.from_metadata(metadata) : metadata.key?('replay') ? KnockoutReplay.from_metadata(metadata) :
        KnockoutRound.from_metadata(metadata)
      base = metadata.dig('series','base_plan') || metadata.dig('replay', 'base_plan') || plan
      mapped = candidate['matches'].each_with_index.to_h do |match, index|
        logical = base['matches'].find { |fixture| fixture['participants'].sort == match.fetch(unit_key).sort }
        raise Publication::Invalid, :sandbox_corrupt unless logical
        [JSON.generate([match['match_id'], match['leg']]), {'id' => logical['id'], 'participants' => logical['participants']}]
      end
      normalized = results.map do |result|
        fixture = mapped[result['id']]
        unless fixture && fixture['participants'].sort == result['participants'].sort
          raise Publication::Invalid, :sandbox_corrupt
        end
        result.merge('id' => fixture['id'], 'participants' => fixture['participants'])
      end
      if metadata['series']
        history=metadata['series']['history']+results
        series=KnockoutWinSeries.progress(base:base,history:history,target:metadata['series']['target'])
        sports=series['sports']
        return {'knockout_state'=>sports['state']=='awaiting_results' ? 'awaiting_series' : sports['state'],
          'knockout_progress'=>sports,'champion'=>sports['champion'],'qualified'=>sports['next_seeds'],
          'knockout_resolved_results'=>series['summaries'],'series_history'=>history,'series_progress'=>series['series'],
          'standings'=>StandingsRanking.calculate(units:units,results:series['summaries'],points:Standings::MATCH_POINTS,criteria:StandingsRanking::CRITERIA)}
      end
      if metadata['qualification']
        progress = GroupTiebreak.progress(plan: plan, results: normalized)
        view = progress['projection'] || {}
        return view.merge('qualification_progress' => progress, 'knockout_state' => 'qualification_tiebreak',
          'standings' => StandingsRanking.calculate(units: units, results: results, points: Standings::MATCH_POINTS, criteria: StandingsRanking::CRITERIA))
      end
      if metadata['rematch']
        normalized = normalized.group_by { |result| result['id'] }.filter_map do |id, rows|
          # Standings validates unique identities while the sports round uses
          # one logical pairing. Preserve distinct leg identities for sums.
          KnockoutSeries.aggregate(units: rows.first['participants'],
            results: rows.each_with_index.map { |row,index| row.merge('id' => "#{id}:#{index}") }, id: id)
        end
      end
      combined = (metadata.dig('replay', 'resolved_results') || []) + normalized
      progress = KnockoutRound.progress(seeds: base['seeds'], players_per_match: base['players_per_match'],
        round_number: base['round'], results: combined, bracket_groups:base['bracket_groups'])
      {'knockout_state' => progress['state'], 'knockout_progress' => progress, 'champion' => progress['champion'],
        'qualified' => progress['next_seeds'], 'knockout_resolved_results' => combined.select { |result| result['winners'].size == 1 || result['resolution'] == 'all_zero' },
        'standings' => StandingsRanking.calculate(units: units, results: results,
          points: Standings::MATCH_POINTS, criteria: StandingsRanking::CRITERIA)}
    end
  end
end
