# encoding: UTF-8
require_relative 'local_fixed_team_moves'
require_relative 'local_fixed_team_standings'
require_relative 'game_result'

module GameRoomTournaments
  class LocalFixedTeamResult < LocalFixedTeamMoves
    C = CoordinationContract
    Data = Publication::Data
    FIELDS = %w[version kind id account binding_digest epoch native_uuid table_id session_id created_at revision
      record_intent plan_id match_id leg summary release_epoch released_accounts].freeze

    def self.summary(execution, core, registry:, result_policy: nil)
      raise Publication::Invalid, :invalid_game_result unless result_policy.nil?
      result = nil
      with_core(core, execution, owner: core['owner']) do |_tx, _transport, _table, repository, session|
        snapshot = repository.snapshot_for(session, force_events: true)
        game = registry.build(execution['request']['game_id'])
        replay = game.replay(snapshot.session, snapshot.events, repository)
        raise C::Blocked, :game_not_finished unless replay.finished? && replay.winner && replay.state[:phase] == :finished
        raise C::Blocked, :invalid_history unless replay.accepted_events.size == snapshot.events.size
        outcome = GameResult.from_replay(game: game, replay: replay, players: execution['request']['players'],
          options: replay.state[:options], event_count: snapshot.events.size)
        raise C::Blocked, :team_mismatch unless outcome['participants'].size == 2 && outcome['winners'].size == 1
        scores = outcome['scores']
        raise C::Blocked, :invalid_history unless scores.values.all? { |value| value.is_a?(Integer) }
        result = {'winner' => outcome['winners'].first, 'scores' => scores,
          'rounds' => replay.state[:round], 'event_count' => snapshot.events.size}
      end
      result
    end

    def self.validate!(execution, core, registry:, result_policy: nil)
      return unless execution.key?('result')
      receipt = execution['result']
      C.fields!(receipt, FIELDS)
      start = execution['start']
      raise Publication::Invalid, :sandbox_corrupt unless start && core
      request = execution['request']
      expected = start.slice('binding_digest', 'epoch', 'native_uuid', 'table_id', 'session_id').merge(
        'version' => 1, 'kind' => 'result', 'account' => execution['coordinator'],
        'record_intent' => execution['record_intent'], 'plan_id' => request['plan_id'],
        'match_id' => request['match_id'], 'leg' => request['leg'], 'release_epoch' => start['epoch'] + 1,
        'released_accounts' => request['players'].map { |p| p['account'] }.sort)
      last_time = (execution['moves'] || []).last&.fetch('created_at') || start['created_at']
      unless expected.all? { |key, value| receipt[key].eql?(value) } && core['closed'].equal?(true) &&
          execution['grant'].nil? && execution['epoch'] >= receipt['release_epoch'] &&
          Data.integer?(receipt['created_at']) && receipt['created_at'] >= last_time &&
          receipt['revision'] == revision(execution, core['entries']) &&
          receipt['summary'].eql?(summary(execution, core, registry: registry, result_policy: result_policy))
        raise Publication::Invalid, :sandbox_corrupt
      end
      Data.text!(receipt['id'], bytes: 256)
    rescue C::Blocked, ArgumentError => error
      raise Publication::Invalid.new(:sandbox_corrupt), cause: error
    end

    def finalize(revision:)
      Data.text!(revision, bytes: 256)
      @record_reader.call(true)
      @port.transaction do |document|
        @record_reader.call(true)
        execution = execution!(document)
        raise C::Blocked, :not_coordinator unless actor == execution['coordinator']
        prior = execution['result']
        if prior
          raise C::Blocked, :stale_view unless revision == prior['revision']
          next detached(prior)
        end
        raise C::Blocked, :start_required unless execution['start']
        raise C::Blocked, :stale_grant unless execution['epoch'] == execution['start']['epoch']
        core = core!(document, execution)
        raise C::Blocked, :stale_view unless revision == self.class.revision(execution, core['entries'])
        result_policy = document['records'].fetch(execution['record_intent'])['evidence']['source']['result_policy']
        summary = self.class.summary(execution, core, registry: @registry, result_policy: result_policy)
        accounts = @request['players'].map { |p| p['account'] }.sort
        raise C::Blocked, :stale_busy unless accounts.all? { |account| document['busy'][account] == @key }
        receipt = execution['start'].slice('binding_digest', 'epoch', 'native_uuid', 'table_id', 'session_id').merge(
          'version' => 1, 'kind' => 'result', 'id' => SecureRandom.uuid, 'account' => actor,
          'created_at' => @clock.call, 'revision' => revision, 'record_intent' => execution['record_intent'],
          'plan_id' => @request['plan_id'], 'match_id' => @request['match_id'], 'leg' => @request['leg'],
          'summary' => summary, 'release_epoch' => execution['epoch'] + 1, 'released_accounts' => accounts)
        @record_reader.call(true)
        execution['result'] = receipt
        execution['epoch'] = receipt['release_epoch']
        execution['grant'] = nil
        core['closed'] = true
        accounts.each { |account| document['busy'].delete(account) }
        @storage.write(document, receipt: receipt)
        detached(receipt)
      end
    end

    def status
      @port.transaction do |document|
        execution = execution!(document)
        value = Data.copy(status_in(document, execution))
        value['result'] = execution['result']
        value['finished'] = value['phase'] == 'finished'
        rows = document['executions'].values.select { |e| e['record_intent'] == execution['record_intent'] && e['result'] }
        value['results'] = rows.map { |e| e['result'] }.sort_by { |r| [r['match_id'], r['leg']] }
        record = document['records'].fetch(execution['record_intent'])
        value['standings'] = LocalFixedTeamStandings.build(record: record, executions: rows)['standings']
        detached(value)
      end
    end
  end
end
