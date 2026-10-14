require_relative '../support/tournament_individual_execution'
include TournamentIndividualExecutionSupport
with_fixture(game: 'battleship', names: %w[Alpha Beta]) do |fixture|
  record = start_individual_match(fixture)
  move = lambda do |actor, id, selection|
    with_individual_execution(fixture, record, actor) do |execution|
      status = execution.local_game(action: :local_game_status)[:status]
      result = execution.local_game(action: :local_game_move, operation_id: id, revision: status['revision'], move_selection: selection)
      assert_equal(:confirmed, result[:state], result.inspect)
      assert_equal(result[:effect], execution.local_game(action: :local_game_move, operation_id: id,
        revision: status['revision'], move_selection: selection)[:effect])
      result
    end
  end
  move.call('Beta', 'private-begin', {'kind' => 'command', 'action' => 'begin'})
  with_individual_execution(fixture, record, 'Beta') do |execution|
    projection = execution.local_game(action: :local_game_surface)[:effect]
    assert(projection[:spec].is_a?(GameSurfaces::FleetGridSpec), 'Use the game-owned fleet input surface')
    assert_equal(execution.local_game(action: :local_game_status)[:status]['revision'], projection[:revision])
  end
  fleet = [[0,1,2,3], [20,21,22], [25,26,27], [40,41], [44,45], [48,49], [60], [62], [64], [66]]
  choice = {'kind' => 'command', 'action' => 'seal', 'ships' => JSON.generate(fleet)}
  move.call('Beta', 'private-beta-fleet', choice)
  move.call('Alpha', 'private-alpha-fleet', choice)
  path = File.join(fixture.directory, 'k02', 'individual-v1', 'execution-v1', 'state.json')
  public_bytes = File.binread(path)
  assert(!public_bytes.include?(JSON.generate(fleet)), 'Private fleet leaked to shared history')
  assert(!public_bytes.include?('"ships"'), 'Private selection body leaked to shared receipt')
  assert_equal(3, JSON.parse(public_bytes)['executions'].values.first['moves'].size)
  shoot = move.call('Beta', 'private-shot', {'kind' => 'grid', 'action' => 'select', 'x' => 0, 'y' => 0})
  assert_equal('answering', shoot[:status]['phase'])
  answer = move.call('Alpha', 'private-answer', {'kind' => 'command', 'action' => 'answer'})
  assert_equal('playing', answer[:status]['phase'])
  assert_equal('answer', answer[:effect]['record']['packet']['data']['events'].first['action'])
  assert(!File.read(path).include?('"ships"'), 'Answer leaked the hidden fleet')
  if ARGV.include?('--full')
    hits = fleet.flatten.drop(1)
    misses = (0...100).to_a - fleet.flatten
    hits.each_with_index do |cell, index|
      miss = misses[index]
      move.call('Alpha', "alpha-shot-#{index}", {'kind' => 'grid', 'action' => 'select', 'x' => miss % 10, 'y' => miss / 10})
      move.call('Beta', "beta-answer-#{index}", {'kind' => 'command', 'action' => 'answer'})
      move.call('Beta', "beta-shot-#{index}", {'kind' => 'grid', 'action' => 'select', 'x' => cell % 10, 'y' => cell / 10})
      move.call('Alpha', "alpha-answer-#{index}", {'kind' => 'command', 'action' => 'answer'})
    end
    move.call('Alpha', 'alpha-open', {'kind' => 'command', 'action' => 'open'})
    finished = move.call('Beta', 'beta-open', {'kind' => 'command', 'action' => 'open'})
    assert_equal('finished', finished[:status]['phase'])
    assert(finished[:effect]['record']['packet']['data']['events'].size > 1, 'Fleet reveal must remain one multi-event action')
    with_individual_execution(fixture, record, 'Beta') do |execution|
      result = execution.local_game(action: :finalize_local_game, revision: finished[:status]['revision'])
      assert_equal(:confirmed, result[:state], result.inspect)
      assert_equal(['beta'], result[:effect]['summary']['winners'])
      assert_equal(1, result[:status]['results'].size)
    end
    puts 'PASS complete private Battleship match: revealed commitments, multi-event opening and actual winner finalized'
  end
  bytes = File.binread(path)
  cold = File.expand_path('../support/tournament_private_game_cold_probe.rb', __dir__)
  output = IO.popen([RbConfig.ruby, cold, fixture.directory, ARGV.include?('--full') ? 'finished' : 'playing'], err: [:child, :out], &:read)
  assert($?.success?, output)
  assert_equal(bytes, File.binread(path))
  document = JSON.parse(bytes)
  document['executions'].values.first['moves'][1]['selection_ref'] = 'f' * 64
  File.binwrite(path, JSON.generate(document))
  begin
    assert_raises(T::Publication::Invalid) do
      with_individual_execution(fixture, record, 'Alpha') { |e| e.local_game(action: :local_game_status) }
    end
  ensure
    File.binwrite(path, bytes)
  end
end
puts 'PASS real Battleship private protocol: own fleet commitments, opaque shared receipts, cross-actor replay validation, own hidden answer and retry identity'
