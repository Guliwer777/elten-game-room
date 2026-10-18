require_relative '../support/tournament_individual_execution'
include TournamentIndividualExecutionSupport

checks = 0
with_fixture(game: 'tic_tac_toe', names: %w[Alpha Beta], rematch: false) do |fixture|
  record = start_individual_match(fixture, intent_id: 'storage-native-replay-shape')
  owner = record.dig('evidence', 'plan', 'matches').first.fetch('players').first.fetch('username')
  player = nil
  with_individual_execution(fixture, record, owner) do |execution|
    player = execution.local_game(action: :local_game_status).fetch(:status).fetch('current_player')
  end
  with_individual_execution(fixture, record, player) do |execution|
    status = execution.local_game(action: :local_game_status).fetch(:status)
    result = execution.local_game(action: :local_game_move, operation_id: 'storage-shape-first-move',
      revision: status.fetch('revision'), move_selection: status.fetch('actions').first)
    assert_equal(:confirmed, result[:state], result.inspect)
    assert_equal(1, result.fetch(:status).fetch('event_count'))
    baseline = execution.progress
    path = execution.instance_variable_get(:@storage).path
    bytes = File.binread(path)
    %w[metadata discovery_metadata].each do |field|
      [nil, true, false, 0, 0.0, '', [], {}].each do |value|
        document = JSON.parse(bytes)
        document.fetch('native').fetch('cores').first[field] = value
        malformed = JSON.generate(document)
        begin
          File.binwrite(path, malformed)
          error = assert_raises(T::Publication::Invalid) { execution.progress }
          assert(error.code.is_a?(Symbol), 'A damaged native container needs a typed refusal')
          assert_equal(malformed.b, File.binread(path), 'A rejected replay must not repair or rewrite its input')
        ensure
          File.binwrite(path, bytes)
        end
        checks += 1
      end
    end
    assert_equal(baseline, execution.progress)
    assert_equal(bytes, File.binread(path))
    assert_equal(1, execution.local_game(action: :local_game_status).fetch(:status).fetch('event_count'))
  end
end
puts "PASS local execution native replay: #{checks} typed metadata refusals after a real move, original progress retained"
