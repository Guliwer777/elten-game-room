# encoding: UTF-8
require_relative 'local_fixed_team_result'

module GameRoomTournaments
  # Read-only projection of accepted matches and their persisted execution.
  class LocalFixedTeamProgress
    Data = Publication::Data
    def self.standings_class; LocalFixedTeamStandings; end
    def self.build(document:, record:, actor:, registry:, now:, all_matches: false)
      intent = record['preview']['intent_id']
      planned = record['evidence']['plan']['matches']
      executions = document['executions'].values.select { |e| e['record_intent'] == intent }
      summary = standings_class.build(record: record, executions: executions)
      rows = planned.select { |m| all_matches || m['players'].any? { |p| p['account'] == actor } }.map do |match|
        execution = executions.find { |e| e['request']['match_id'] == match['match_id'] && e['request']['leg'] == match['leg'] }
        window = execution ? execution['request']['window'] :
          (match['windows'].find { |w| now < w['closes'] } || match['windows'].last)
        stage, action = 'planned', 'inspect'
        interruption_reason = nil
        if execution && execution['result']
          stage, action = 'completed', 'local_game_status'
        elsif execution && execution['start']
          core = document['native']['cores'].find { |c| c['id'] == execution['start']['native_uuid'] }
          LocalFixedTeamMoves.with_core(core, execution, owner: core['owner']) do |_tx, _transport, _table, repository, session|
            snapshot = repository.snapshot_for(session, force_events: true)
            replay = registry.build(match['game_id']).replay(snapshot.session, snapshot.events, repository)
            stage = replay.finished? ? 'awaiting_result' : 'playing'
          end
          stage = 'interrupted' if execution['epoch'] != execution['start']['epoch']
          stage = 'interrupted' if stage == 'playing' && now >= window['closes']
          interruption_reason = execution['epoch'] != execution['start']['epoch'] ? 'authority_changed' : 'window_expired' if stage == 'interrupted'
          action = 'local_game_status'
        elsif execution && execution['target']
          stage, action = 'awaiting_entry', 'admission_status'
          stage = 'ready_to_start' if (execution.dig('admission', 'entries') || {}).size == match['players'].size
          grant = execution['grant']
          stage = 'interrupted' unless grant && grant['fencing'] == execution['epoch'] && now < grant['expires_at']
          interruption_reason = grant && grant['fencing'] == execution['epoch'] ? 'authorization_expired' : 'authority_changed' if stage == 'interrupted'
        elsif execution
          stage = 'preparing'
        end
        {'match_id' => match['match_id'], 'leg' => match['leg'], 'stage' => stage, 'interruption_reason' => interruption_reason,
          'result' => execution && execution.dig('result', 'summary'),
          'window_open' => window['opens'] <= now && now < window['closes'],
          'window_expired' => now >= window['closes'], 'action' => action,
          'selectors' => {'intent_id' => intent, 'match_id' => match['match_id'], 'leg' => match['leg'], 'window_id' => window['id']}}
      end
      priority = %w[awaiting_result playing ready_to_start awaiting_entry preparing planned interrupted completed]
      recommendation = rows.reject { |r| r['stage'] == 'completed' }.min_by do |row|
        [row['stage'] == 'awaiting_result' ? 0 : 1, row['window_expired'] ? 1 : 0,
          row['window_open'] ? 0 : 1, priority.index(row['stage']), row['match_id'], row['leg']]
      end
      Data.freeze_tree(Data.copy(summary.merge('matches' => rows, 'recommendation' => recommendation),
        max_bytes: 262_144, max_nodes: 16_384, max_depth: 12))
    end
  end
end
