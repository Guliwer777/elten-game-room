require 'digest'
require 'json'
require_relative 'coordination_contract'
module GameRoomTournaments
  module LocalOrganizerResult
    Data = Publication::Data
    C = CoordinationContract
    FIELDS = %w[version kind id account record_intent plan_id plan_digest match_id leg created_at revision reason summary release_epoch released_accounts].freeze
    def self.units(record, request)
      request['players'].map { |person| record['evidence']['version'] == 2 ? person['team'] : person['account'] }.uniq.sort
    end
    def self.revision(execution)
      Digest::SHA256.hexdigest(JSON.generate(execution))
    end
    def self.validate!(execution, core, record)
      receipt = execution['result']
      C.fields!(receipt, FIELDS)
      request = execution['request']
      participants = units(record, request)
      expected = {'version' => 1, 'kind' => 'forfeit', 'account' => record['preview']['source']['candidate']['publication_ref']['author'],
        'record_intent' => record['preview']['intent_id'], 'plan_id' => request['plan_id'],
        'plan_digest' => record['evidence']['plan_digest'], 'match_id' => request['match_id'], 'leg' => request['leg'],
        'released_accounts' => request['players'].map { |person| person['account'] }.sort}
      summary = receipt['summary']
      C.fields!(summary, %w[participants winners scores draw])
      unless expected.all? { |key, value| receipt[key] == value } && summary['participants'] == participants &&
          summary['winners'].is_a?(Array) && summary['winners'].size == 1 && participants.include?(summary['winners'].first) &&
          summary['scores'].nil? && summary['draw'] == false && Data.integer?(receipt['created_at']) &&
          Data.integer?(receipt['release_epoch'], 2) && execution['epoch'] >= receipt['release_epoch'] &&
          execution['grant'].nil? && (!core || core['closed'] == true)
        raise Publication::Invalid, :sandbox_corrupt
      end
      Data.text!(receipt['id'], bytes: 256)
      Data.text!(receipt['reason'], bytes: 4096, multiline: true)
      raise Publication::Invalid, :sandbox_corrupt if receipt['reason'].strip.empty?
      boundary = [execution.dig('start', 'created_at'), execution.dig('moves')&.last&.fetch('created_at')].compact.max || 0
      raise Publication::Invalid, :sandbox_corrupt if receipt['created_at'] < boundary
      Data.key!(receipt['revision'])
    end
    def organizer_result_status
      record!(true)
      request = selection[:request].to_h
      key = C.digest(request.values_at('scope', 'match_id', 'leg', 'execution_generation'))
      @port.transaction do |document|
        execution = document['executions'][key]
        {state: :confirmed, revision: LocalOrganizerResult.revision(execution), result: execution && execution['result'],
          units: LocalOrganizerResult.units(selection[:record], request)}.freeze
      end
    end
    def organizer_forfeit(operation_id:, winner:, reason:, expected_revision:)
      record!(true)
      record, request = selection.values_at(:record, :request)
      request = request.to_h
      raise C::Blocked, :not_author unless record['preview']['source']['candidate']['publication_ref']['author'] == @expected['account']
      Data.text!(operation_id, bytes: 256)
      Data.text!(reason, bytes: 4096, multiline: true)
      raise C::Blocked, :missing_reason if reason.strip.empty?
      Data.key!(expected_revision)
      units = LocalOrganizerResult.units(record, request)
      raise C::Blocked, :invalid_winner unless units.include?(winner)
      key = C.digest(request.values_at('scope', 'match_id', 'leg', 'execution_generation'))
      @port.transaction do |document|
        record!(true)
        @storage.remember_record(document, record)
        execution = document['executions'][key]
        prior = execution && execution['result']
        if prior
          raise C::Blocked, :result_already_recorded unless prior['kind'] == 'forfeit' && prior['id'] == operation_id &&
            prior['reason'] == reason && prior['summary']['winners'] == [winner] && prior['revision'] == expected_revision
          next({state: :confirmed, effect: prior}.freeze)
        end
        raise C::Blocked, :stale_view unless LocalOrganizerResult.revision(execution) == expected_revision
        core = execution && execution['target'] && document['native']['cores'].find { |row| row['id'] == execution['target']['binding']['native_uuid'] }
        if execution && execution['start']
          LocalFixedTeamMoves.with_core(core, execution, owner: core['owner']) do |_tx, _transport, _table, repository, session|
            snapshot = repository.snapshot_for(session, force_events: true)
            game = @registry.build(request['game_id'])
            replay = game.replay(snapshot.session, snapshot.events, repository)
            raise C::Blocked, :game_already_finished if replay.finished?
            raise C::Blocked, :private_phase_pending if game.controller_change_error(replay)
          end
        end
        now = @clock.call
        raise C::Blocked, :invalid_clock unless Data.integer?(now) && now >= (execution && execution['moves']&.last&.fetch('created_at') || 0)
        execution ||= {'request' => request, 'record_intent' => record['preview']['intent_id'],
          'epoch' => document['executions'].values.map { |row| row['epoch'] }.max.to_i + 1,
          'coordinator' => request['players'].first['account'], 'policy_ref' => @policy_ref, 'expires_at' => request['window']['closes'],
          'grant' => nil, 'operations' => {}, 'target' => nil}
        receipt = {'version' => 1, 'kind' => 'forfeit', 'id' => operation_id, 'account' => @expected['account'],
          'record_intent' => record['preview']['intent_id'], 'plan_id' => request['plan_id'], 'plan_digest' => record['evidence']['plan_digest'],
          'match_id' => request['match_id'], 'leg' => request['leg'], 'created_at' => now, 'revision' => expected_revision, 'reason' => reason,
          'summary' => {'participants' => units, 'winners' => [winner], 'scores' => nil, 'draw' => false},
          'release_epoch' => execution['epoch'] + 1, 'released_accounts' => request['players'].map { |person| person['account'] }.sort}
        execution['result'], execution['grant'], execution['epoch'] = receipt, nil, receipt['release_epoch']
        document['executions'][key] = execution
        core['closed'] = true if core
        receipt['released_accounts'].each { |account| document['busy'].delete(account) if document['busy'][account] == key }
        record!(true)
        @storage.write(document, receipt: receipt)
        {state: :confirmed, effect: receipt}.freeze
      end
    rescue LocalFixedTeamExecutionStorage::Unconfirmed => error
      {state: :uncertain, receipt: error.receipt}.freeze
    rescue C::Blocked => error
      {state: :blocked, reason: error.code}.freeze
    end
  end
end
