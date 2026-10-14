require_relative '../support/tournament_individual_execution'
include TournamentIndividualExecutionSupport
[{game: 'tic_tac_toe', names: %w[Alpha Beta]},
 {game: 'future_individual', names: %w[Alpha Beta], registry: future_individual_registry},
 {game: 'tic_tac_toe', names: %w[Alpha Beta], draw: true},
 {game: 'farkle', names: %w[Alpha Beta Gamma], players_per_match: 3}].each do |scenario|
with_fixture(**scenario.reject { |key, _| key == :draw }) do |fixture|
  backend = fixture.backend
  record = backend.accept(preview: backend.preview(publication_ref: fixture.reference,
    base_seats: fixture.base, intent_id: 'individual-start'))
  scenario[:names].each do |actor|
    with_individual_execution(fixture, record, actor) do |execution|
      assert_equal(:confirmed, execution.declare(availability: 'ready', expected_revision: 0)[:state])
    end
  end
  digest = nil
  with_individual_execution(fixture, record, 'Alpha') do |execution|
    result = execution.request_match
    assert_equal(:bound, result[:state], result.inspect)
    digest = T::CoordinationContract.digest(execution.admission(action: :admission_status)[:status]['binding'])
    assert_equal(:entries_required, execution.local_game(action: :start_local_game, binding_digest: digest)[:reason])
  end
  scenario[:names].each do |actor|
    with_individual_execution(fixture, record, actor) do |execution|
      consent = execution.admission(action: :consent, binding_digest: digest)
      assert_equal(:confirmed, consent[:state])
      assert_equal(:confirmed, execution.admission(action: :enter, consent_id: consent[:effect]['id'])[:state])
    end
  end
  with_individual_execution(fixture, record, 'Beta') do |execution|
    assert_equal(:not_coordinator, execution.local_game(action: :start_local_game, binding_digest: digest)[:reason])
  end
  receipt = nil
  with_individual_execution(fixture, record, 'Alpha') do |execution|
    result = execution.local_game(action: :start_local_game, binding_digest: digest)
    assert_equal(:confirmed, result[:state], result.inspect)
    assert_equal('playing', result[:status]['phase']) if scenario[:game] != 'farkle'
    assert_equal(0, result[:status]['event_count'])
    receipt = result[:effect]
    assert_equal(receipt, execution.local_game(action: :start_local_game, binding_digest: digest)[:effect])
  end
  with_individual_execution(fixture, record, 'Beta') do |execution|
    assert_equal(receipt, execution.local_game(action: :local_game_status)[:status]['receipt'])
  end
  path = File.join(fixture.directory, 'k02', 'individual-v1', 'execution-v1', 'state.json')
  document = JSON.parse(File.read(path))
  assert_equal(1, document['native']['creates'].size)
  assert_equal(scenario[:names].size, document['native']['cores'].first['capacity'])
  assert_equal(1, document['native']['cores'].first['entries'].count { |r| r['packet']['kind'] == 'game_started' })
  bytes = File.binread(path)
  cold = File.expand_path('../support/tournament_individual_start_cold_probe.rb', __dir__)
  output = IO.popen([RbConfig.ruby, cold, fixture.directory, scenario[:game]], err: [:child, :out], &:read)
  assert($?.success?, output)
  assert(output.include?('PASS cold individual Start'), output)
  assert_equal(bytes, File.binread(path))
  document['native']['cores'].first['capacity'] += 1
  File.binwrite(path, JSON.generate(document))
  begin
    assert_raises(T::Publication::Invalid) do
      with_individual_execution(fixture, record, 'Beta') { |e| e.local_game(action: :local_game_status) }
    end
  ensure
    File.binwrite(path, bytes)
  end
  coordinates = if scenario[:draw]
    [[0,0],[1,0],[2,0],[1,1],[0,1],[2,1],[1,2],[0,2],[2,2]]
  elsif scenario[:game] != 'farkle'
    [[0,0],[0,1],[1,0],[1,1],[2,0]]
  else
    [nil]
  end
  coordinates.each_with_index do |coordinate, index|
    status = nil
    with_individual_execution(fixture, record, 'Alpha') do |execution|
      status = execution.local_game(action: :local_game_status)[:status]
    end
    with_individual_execution(fixture, record, status['current_player']) do |execution|
      own = execution.local_game(action: :local_game_status)[:status]
      selection = coordinate ? own['actions'].find { |a| a['x'] == coordinate[0] && a['y'] == coordinate[1] } : own['actions'].first
      assert(selection, own.inspect)
      result = execution.local_game(action: :local_game_move, operation_id: "individual-move-#{index}",
        revision: own['revision'], move_selection: selection)
      assert_equal(:confirmed, result[:state], result.inspect)
      assert_equal(index + 1, result[:status]['event_count'])
      repeated = execution.local_game(action: :local_game_move, operation_id: "individual-move-#{index}",
        revision: own['revision'], move_selection: selection)
      assert_equal(result[:effect], repeated[:effect])
    end
  end
  with_individual_execution(fixture, record, 'Alpha') do |execution|
    status = execution.local_game(action: :local_game_status)[:status]
    if scenario[:game] != 'farkle'
      assert_equal('finished', status['phase'])
      finalized = execution.local_game(action: :finalize_local_game, revision: status['revision'])
      assert_equal(:confirmed, finalized[:state], finalized.inspect)
      assert_equal(scenario[:draw] ? [] : ['beta'], finalized[:effect]['summary']['winners'])
      assert_equal(nil, finalized[:effect]['summary']['scores'])
      row = finalized[:status]['standings'].find { |r| r['unit'] == 'beta' }
      assert_equal(1, row[scenario[:draw] ? 'draws' : 'wins'])
      assert_equal(finalized[:effect], execution.local_game(action: :finalize_local_game, revision: status['revision'])[:effect])
      assert_equal(1, execution.progress['completed'])
      assert_equal(1, execution.progress['remaining'])
    end
  end
  saved = File.binread(path)
  document = JSON.parse(saved)
  execution = document['executions'].values.first
  if scenario[:game] != 'farkle'
    assert_equal({}, document['busy'])
    assert_equal(true, document['native']['cores'].first['closed'])
    execution['moves'].last['selection']['x'] = 0
    execution['moves'].last['selection']['y'] = 2
  else
    roll = execution['moves'].first['randomness'].first
    roll['values'][0] = roll['values'][0] % 6 + 1
  end
  File.binwrite(path, JSON.generate(document))
  begin
    assert_raises(T::Publication::Invalid) do
      with_individual_execution(fixture, record, 'Beta') { |e| e.local_game(action: :local_game_status) }
    end
  ensure
    File.binwrite(path, saved)
  end
  output = IO.popen([RbConfig.ruby, cold, fixture.directory, scenario[:game], coordinates.size.to_s], err: [:child, :out], &:read)
  assert($?.success?, output)
  assert_equal(saved, File.binread(path))
end
end
realtime = Class.new(GameRoomGames::TicTacToe) do
  def id; 'future_realtime'; end
  def session_runner?; false; end
end
with_fixture(game: 'future_realtime', registry: GameRoomGames::Registry.new([realtime])) do |fixture|
  backend = fixture.backend
  record = backend.accept(preview: backend.preview(publication_ref: fixture.reference,
    base_seats: fixture.base, intent_id: 'realtime-plan'))
  error = assert_raises(T::Publication::Invalid) do
    with_individual_execution(fixture, record, 'Alpha') { |_execution| raise 'Started realtime in turn-based executor' }
  end
  assert_equal(:realtime_execution_required, error.code)
end
puts 'PASS individual native Start/moves/result: two/three players, real Runner, board without state, recorded dice, immutable selection/randomness, cold replay and atomic result release'
