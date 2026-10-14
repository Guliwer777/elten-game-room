# encoding: UTF-8
require_relative '../support/tournament_moves_fixture'
include GameRoomTest::Assertions
F = TournamentFT2B1
T = F::T
module Session
  def self.name; 'RealAuthenticatedUser'; end
end unless defined?(Session)
fixture = TournamentMovesFixture.build
record = fixture[:record]
begin
  original_host_user = Session.name
  F.with_execution(fixture, 'Ala') do |execution|
    F.select_execution(execution, record)
    status = execution.local_game(action: :local_game_status)[:status]
    assert_equal([], status['actions'])
    assert_equal(:invalid_action, execution.local_game(action: :local_game_move, operation_id: 'wrong-dealer',
      revision: status['revision'], move_selection: {'kind' => 'command', 'action' => 'deal'})[:reason])
  end
  F.with_execution(fixture, 'Beata') do |execution|
    F.select_execution(execution, record)
    status = execution.local_game(action: :local_game_status)[:status]
    assert_equal([{'kind' => 'command', 'action' => 'deal'}], status['actions'])
    fault = Module.new do
      def write(document, receipt: nil)
        result = super
        if $move_lose_response && receipt && receipt['kind'] == 'move'
          $move_lose_response = false
          raise GameRoomTournaments::LocalFixedTeamExecutionStorage::Unconfirmed.new(attempt_id: 'lost-move', receipt: receipt)
        end
        result
      end
    end
    T::LocalFixedTeamExecutionStorage.prepend(fault)
    $move_lose_response = true
    uncertain = execution.local_game(action: :local_game_move, operation_id: 'first-deal', revision: status['revision'], move_selection: status['actions'].first)
    assert_equal(:uncertain, uncertain[:state])
    recovered = execution.local_game(action: :local_move_status, operation_id: 'first-deal')
    assert_equal(uncertain[:receipt], recovered[:effect])
    assert_equal(:unknown, execution.local_game(action: :local_move_status, operation_id: 'never-written')[:state])
    result = execution.local_game(action: :local_game_move, operation_id: 'first-deal', revision: status['revision'], move_selection: status['actions'].first)
    assert_equal(:confirmed, result[:state])
    assert_equal('bidding', result[:status]['phase'])
    assert_equal(1, result[:status]['event_count'])
    assert_equal(result[:effect], execution.local_game(action: :local_game_move, operation_id: 'first-deal', revision: status['revision'], move_selection: status['actions'].first)[:effect])
    assert_equal(:stale_view, execution.local_game(action: :local_game_move, operation_id: 'stale-deal', revision: status['revision'], move_selection: status['actions'].first)[:reason])
    assert_equal(:operation_conflict, execution.local_game(action: :local_game_move, operation_id: 'first-deal', revision: 'different', move_selection: status['actions'].first)[:reason])
  end
  read = nil
  F.with_execution(fixture, 'Anna') do |execution|
    F.select_execution(execution, record)
    read = execution.local_game(action: :local_game_status)[:status]
  end
  bidder = read['current_player']
  F.with_execution(fixture, bidder) do |execution|
    F.select_execution(execution, record)
    status = execution.local_game(action: :local_game_status)[:status]
    selection = status['actions'].first
    assert(selection, 'No real legal bid')
    assert_equal(:confirmed, execution.local_game(action: :local_game_move, operation_id: 'first-bid', revision: status['revision'], move_selection: selection)[:state])
  end
  # Finish bidding and play a physical card through the same runner boundary.
  latest = nil
  3.times do |index|
    F.with_execution(fixture, 'Anna') do |execution|
      F.select_execution(execution, record)
      latest = execution.local_game(action: :local_game_status)[:status]
    end
    F.with_execution(fixture, latest['current_player']) do |execution|
      F.select_execution(execution, record)
      status = execution.local_game(action: :local_game_status)[:status]
      result = execution.local_game(action: :local_game_move, operation_id: "bid-#{index + 2}",
        revision: status['revision'], move_selection: status['actions'].first)
      assert_equal(:confirmed, result[:state])
      latest = result[:status]
    end
  end
  assert_equal('playing', latest['phase'])
  # The technical Start deadline does not cut off an already started game.
  state_path = File.join(fixture[:plans], 'fixed-teams-v1', 'execution-ft2-v1', 'state.json')
  initial = JSON.parse(File.read(state_path))
  fixture[:now] = initial['executions'].values.find { |r| r['start'] }['expires_at'] + 1
  F.with_execution(fixture, latest['current_player']) do |execution|
    F.select_execution(execution, record)
    status = execution.local_game(action: :local_game_status)[:status]
    assert_equal('card', status['actions'].first['kind'])
    result = execution.local_game(action: :local_game_move, operation_id: 'first-card',
      revision: status['revision'], move_selection: status['actions'].first)
    assert_equal(:confirmed, result[:state])
    assert_equal(6, result[:status]['event_count'])
  end
  assert_equal(original_host_user, Session.name)
  F.with_execution(fixture, 'Ala') do |execution|
    F.select_execution(execution, record)
    assert_equal(:bound, execution.reconcile[:state])
    assert_equal(6, execution.local_game(action: :local_game_status)[:status]['event_count'])
  end
  assert_equal(0, fixture[:program].class.app_runtime.managed_resources.size)
  state_path = File.join(fixture[:plans], 'fixed-teams-v1', 'execution-ft2-v1', 'state.json')
  File.write(File.expand_path('../../tmp/moves-live-fixture-path.txt', __dir__), state_path)
  bytes = File.binread(state_path)
  document = JSON.parse(bytes)
  core = document['native']['cores'].first
  execution_data = document['executions'].values.find { |r| r['start'] }
  expected_hash = nil
  T::LocalFixedTeamMoves.with_core(core, execution_data, owner: core['owner']) do |_tx, _transport, _table, repository, session|
    snapshot = repository.snapshot_for(session, force_events: true)
    replay = F::REGISTRY.build('spades').replay(snapshot.session, snapshot.events, repository)
    expected_hash = Digest::SHA256.hexdigest(JSON.generate(replay.state))
  end
  script = File.expand_path('../support/tournament_moves_cold_probe.rb', __dir__)
  output = IO.popen([RbConfig.ruby, '-EUTF-8', script, File.dirname(fixture[:sandbox]), fixture[:now].to_s, expected_hash], err: [:child, :out], &:read)
  assert($?.success?, "Cold moves failed: #{output}")
  assert(output.include?('PASS cold moves'), 'No cold move evidence')
  assert_equal(Digest::SHA256.hexdigest(bytes), Digest::SHA256.file(state_path).hexdigest)
  tampered = JSON.parse(bytes)
  bad = tampered['executions'].values.find { |r| r['moves'] }
  bad['moves'].first['record']['packet']['data']['events'].first['value'] = '2|0|bad'
  tampered['native']['cores'].first['entries'][2] = bad['moves'].first['record']
  File.binwrite(state_path, JSON.generate(tampered))
  begin
    F.with_execution(fixture, 'Anna') do |execution|
      F.select_execution(execution, record, history: true)
      begin
        execution.local_game(action: :local_game_status)
        raise 'Accepted invalid deal history'
      rescue T::Publication::Invalid => error
        assert_equal(:sandbox_corrupt, error.code)
      end
    end
  ensure
    File.binwrite(state_path, bytes)
  end
  F.with_execution(fixture, 'Anna') do |execution, _backend, session|
    F.select_execution(execution, record)
    status = execution.local_game(action: :local_game_status)[:status]
    session.choose_actor('Ala'); session.choose_actor('Anna')
    assert_equal(:context_changed, execution.local_game(action: :local_game_move, operation_id: 'obsolete-context',
      revision: status['revision'], move_selection: {'kind' => 'command', 'action' => 'deal'})[:reason])
  end
  F.with_execution(fixture, 'Ala') do |execution|
    F.select_execution(execution, record)
    status = execution.local_game(action: :local_game_status)[:status]
    fixture[:now] = record['evidence']['plan']['matches'].first['windows'].first['closes']
    assert_equal(:outside_window, execution.local_game(action: :local_game_move, operation_id: 'after-window',
      revision: status['revision'], move_selection: {'kind' => 'command', 'action' => 'deal'})[:reason])
    fixture[:now] -= 1
    execution.revoke_coordinator(expected_epoch: execution.coordinator_epoch)
    assert_equal(:stale_grant, execution.local_game(action: :local_game_move, operation_id: 'after-revoke',
      revision: status['revision'], move_selection: {'kind' => 'command', 'action' => 'deal'})[:reason])
  end
  puts 'PASS local moves: real runner deal/bid, own actor, stale view, idempotency, replay, no host impersonation'
ensure
  fixture[:program].finalize
  fixture[:program].class.app_runtime.close
end
