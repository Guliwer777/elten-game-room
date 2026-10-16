require_relative 'group_qualification'
require_relative 'compact_group_seeding'
require_relative 'league_plan'
require_relative 'coordination_request'
require 'digest'
require 'json'

module GameRoomTournaments
  # Additional real games decide sporting order without adding points to the
  # original group table. Every snapshot is carried by its reviewed lineage.
  module GroupTiebreak
    module_function
    def snapshot(summary:, candidate:, record: nil)
      Publication::Data.copy({'policy' => candidate['group_advancement'], 'groups' => summary.fetch('groups'),
        'results_by_group' => summary.fetch('group_results'), 'wildcard_order' => {},
        'membership' => candidate['membership'], 'roster' => record && record.dig('evidence','source','roster')},
        max_bytes: 1_048_576, max_nodes: 65_536, max_depth: 16)
    end
    def projection(snapshot)
      groups = snapshot.fetch('groups')
      state = if groups.any? { |g| g['qualification']['state'] == 'tie_requires_resolution' }
        'tie_requires_resolution'
      else
        'awaiting_seeding'
      end
      cross = nil
      if state == 'awaiting_seeding'
        cross = snapshot['policy'] == GroupAdvancement::COMPACT ?
          CompactGroupSeeding.build(groups: groups, results_by_group: snapshot['results_by_group'], wildcard_order: snapshot['wildcard_order']) :
          CrossGroupSeeding.build(groups: groups)
        state = cross['state'] == 'ready' ? 'ready_knockout' : 'seeding_tie_requires_resolution'
      end
      {'group_state' => state, 'groups' => groups, 'group_results' => snapshot['results_by_group'], 'cross_seeding' => cross,
        'qualified' => cross && cross['state'] == 'ready' ? cross['seeds'] : groups.flat_map { |g| g['qualification']['qualified'] }}
    end
    def tasks(snapshot)
      groups = snapshot['groups']
      total = groups.sum { |g| g['units'].size }
      target = GroupAdvancement.target(total, policy: snapshot['policy'])
      extra = target % groups.size
      minimum = groups.select { |g| g['units'].size > g['places'] }.map { |g| g['units'].size }.min
      tasks = groups.flat_map do |group|
        table = group['qualification']['standings']
        table.group_by { |row| row['place'] }.filter_map do |place, tied|
          relevant = place <= group['places'] || (extra.positive? &&
            (place <= group['places'] + 1 || (group['units'].size > minimum && place == table.last['place'])))
          next unless tied.size > 1 && relevant
          {'group' => group['id'], 'place' => place, 'units' => tied.map { |row| row['unit'] }.sort}
        end
      end
      return tasks unless tasks.empty?
      view = projection(snapshot)
      unresolved = view.dig('cross_seeding', 'unresolved') || []
      unresolved.size > 1 ? [{'group' => nil, 'place' => 0, 'units' => unresolved.sort}] : []
    end
    def build(snapshot:, attempt:)
      raise Publication::Invalid, :invalid_knockout_configuration unless Publication::Data.integer?(attempt,1) && attempt <= 255
      pending = tasks(snapshot)
      raise Publication::Invalid, :invalid_phase_results if pending.empty?
      qualification = {'snapshot' => snapshot, 'tasks' => pending, 'attempt' => attempt}
      generation = Digest::SHA256.hexdigest(JSON.generate(['group-tiebreak-v1', qualification]))
      matches = pending.flat_map do |task|
        LeaguePlan.build(participants: task['units'], players_per_match: 2, pairing: 'all_combinations', rematch: false)
          .map { |match| {'id' => '', 'participants' => match['players']} }
      end
      raise Publication::Invalid, :plan_too_large if matches.size > 256
      matches.each_with_index { |match,index| match['id'] = "#{generation}:#{index+1}" }
      seeds = pending.flat_map { |task| task['units'] }.uniq.sort
      Publication::Data.freeze_tree(Publication::Data.copy({'generation' => generation, 'round' => attempt,
        'seeds' => seeds, 'players_per_match' => 2, 'byes' => [], 'matches' => matches,
        'dispatch_allowed' => false, 'qualification' => qualification}, max_bytes: 1_048_576, max_nodes: 65_536, max_depth: 16))
    end
    def from_metadata(metadata)
      proof = metadata.fetch('qualification')
      CoordinationRequest.fields!(proof, %w[snapshot tasks attempt])
      plan = build(snapshot: proof['snapshot'], attempt: proof['attempt'])
      raise Publication::Invalid, :phase_changed unless plan['qualification'] == proof &&
        plan.slice('round','seeds','players_per_match','generation') == metadata.slice('round','seeds','players_per_match','generation')
      plan
    end
    def progress(plan:, results:)
      snapshot = Publication::Data.copy(plan['qualification']['snapshot'])
      index = plan['matches'].to_h { |m| [m['id'], m['participants']] }
      Standings.calculate(units: plan['seeds'], results: results)
      raise Publication::Invalid, :invalid_phase_results unless results.all? { |r| index[r['id']] == r['participants'] }
      return {'state' => 'awaiting_results', 'snapshot' => snapshot} unless results.size == index.size
      plan['qualification']['tasks'].each do |task|
        own = results.select { |r| (r['participants'] - task['units']).empty? }
        ranked = StandingsRanking.calculate(units: task['units'], results: own, points: Standings::MATCH_POINTS, criteria: StandingsRanking::CRITERIA)
        order = ranked.to_h { |row| [row['unit'], row['place']] }
        if task['group']
          group = snapshot['groups'].find { |g| g['id'] == task['group'] }
          table = group['qualification']['standings'].map do |row|
            order.key?(row['unit']) ? row.merge('place' => task['place'] + order[row['unit']] - 1) : row
          end.sort_by { |row| [row['place'], row['unit']] }
          group['qualification'] = GroupQualification.from_table(table: table, places: group['places'])
        else
          snapshot['wildcard_order'].merge!(order)
        end
      end
      view = projection(snapshot)
      {'state' => view['group_state'], 'snapshot' => snapshot, 'projection' => view}
    end
  end
end
