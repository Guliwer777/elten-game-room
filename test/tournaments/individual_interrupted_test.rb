require_relative '../support/tournament_individual_execution'
include TournamentIndividualExecutionSupport
with_fixture(game: 'tic_tac_toe', names: %w[Alpha Beta], rematch: false) do |fixture|
  record = start_individual_match(fixture, intent_id: 'interrupted-match')
  match = record['evidence']['plan']['matches'].first
  actor = match['players'].sort_by { |person| person['seat'] }.first['username']
  path = File.join(fixture.directory, 'k02/individual-v1/execution-v1/state.json')
  with_individual_execution(fixture, record, actor) do |execution|
    status = execution.local_game(action: :local_game_status)[:status]
    effect = execution.local_game(action: :local_game_move, operation_id: 'before-interruption', revision: status['revision'],
      move_selection: {'kind' => 'grid', 'action' => 'select', 'x' => 0, 'y' => 0})
    assert_equal(:confirmed, effect[:state], effect.inspect)
    bytes = File.binread(path)
    document = JSON.parse(bytes)
    progress = T::LocalIndividualProgress.build(document: document, record: record, actor: actor.downcase,
      registry: fixture.registry, now: match['windows'].first['closes'])
    assert_equal('interrupted', progress['matches'].first['stage'])
    assert_equal('window_expired', progress['matches'].first['interruption_reason'])
    assert_equal(bytes, File.binread(path))
    execution.revoke_coordinator(expected_epoch: execution.coordinator_epoch)
  end
  bytes = File.binread(path)
  with_individual_execution(fixture, record, actor) do |execution|
    assert_equal('interrupted', execution.progress['matches'].first['stage'])
    assert_equal('authority_changed', execution.progress['matches'].first['interruption_reason'])
    status = execution.local_game(action: :local_game_status)[:status]
    assert_equal(1, status['event_count'])
    effect = execution.local_game(action: :local_game_move, operation_id: 'after-interruption', revision: status['revision'],
      move_selection: {'kind' => 'grid', 'action' => 'select', 'x' => 1, 'y' => 0})
    assert_equal(:blocked, effect[:state])
    assert_equal(:stale_grant, effect[:reason])
    assert_equal(:blocked, execution.reconcile[:state])
    assert_equal(:blocked, execution.request_match[:state])
  end
  assert_equal(bytes, File.binread(path))
  document = JSON.parse(bytes)
  assert_equal(2, document['busy'].size)
  assert_equal(nil, document['executions'].values.first['result'])
end
puts 'PASS interruption: expired window classification, revoked authority, history retained, no synthetic result or busy release'
