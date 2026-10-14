require_relative '../support/tournament_individual_execution'
include TournamentIndividualExecutionSupport
with_fixture(game: 'rummy', names: %w[Alpha Beta]) do |fixture|
  record = start_individual_match(fixture)
  players = record['evidence']['plan']['matches'].first['players'].map { |p| p['username'] }
  with_individual_execution(fixture, record, players.first) do |execution|
    status = execution.local_game(action: :local_game_status)[:status]
    selection = status['actions'].first
    result = execution.local_game(action: :local_game_move, operation_id: 'batch-deal', revision: status['revision'], move_selection: selection)
    assert_equal(:confirmed, result[:state], result.inspect)
    commands = result[:effect]['record']['packet']['data']['events']
    assert(commands.size > 1, 'Rummy deal did not exercise real fragmented action')
    assert_equal(commands.size, result[:status]['event_count'])
    assert_equal(result[:effect], execution.local_game(action: :local_game_move, operation_id: 'batch-deal',
      revision: status['revision'], move_selection: selection)[:effect])
  end
  current = nil
  with_individual_execution(fixture, record, players.first) do |execution|
    current = execution.local_game(action: :local_game_status)[:status]['current_player']
  end
  with_individual_execution(fixture, record, current) do |execution|
    status = execution.local_game(action: :local_game_status)[:status]
    result = execution.local_game(action: :local_game_move, operation_id: 'batch-next', revision: status['revision'], move_selection: status['actions'].first)
    assert_equal(:confirmed, result[:state], result.inspect)
    assert_equal(status['event_count'], result[:effect]['record']['packet']['data']['sequence'])
  end
  path = File.join(fixture.directory, 'k02', 'individual-v1', 'execution-v1', 'state.json')
  bytes = File.binread(path)
  document = JSON.parse(bytes)
  row = document['executions'].values.first['moves'].first['record']
  row['packet']['data']['events'].reverse!
  document['native']['cores'].first['entries'][2] = row
  File.binwrite(path, JSON.generate(document))
  begin
    assert_raises(T::Publication::Invalid) do
      with_individual_execution(fixture, record, players.first) { |e| e.local_game(action: :local_game_status) }
    end
  ensure
    File.binwrite(path, bytes)
  end
  with_individual_execution(fixture, record, players.first) do |execution|
    assert_equal(2, execution.local_game(action: :local_game_status)[:status]['last_move'] ? JSON.parse(File.read(path))['executions'].values.first['moves'].size : 0)
  end
end
puts 'PASS real Rummy multi-command actions through Runner: atomic packets, event offsets, idempotence, exact replay and reordered fragment rejection'
