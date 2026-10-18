require_relative '../support/tournament_individual_execution'
include TournamentIndividualExecutionSupport

checks = 0
with_fixture(game: 'tic_tac_toe', names: %w[Alpha Beta], rematch: false) do |fixture|
  record = start_individual_match(fixture, intent_id: 'storage-native-visibility')
  owner = record.dig('evidence', 'plan', 'matches').first.fetch('players').first.fetch('username')
  player = nil
  with_individual_execution(fixture, record, owner) do |execution|
    player = execution.local_game(action: :local_game_status).fetch(:status).fetch('current_player')
  end
  with_individual_execution(fixture, record, player) do |execution|
    status = execution.local_game(action: :local_game_status).fetch(:status)
    move = execution.local_game(action: :local_game_move, operation_id: 'visibility-first-move',
      revision: status.fetch('revision'), move_selection: status.fetch('actions').first)
    assert_equal(:confirmed, move[:state])
    assert_equal(1, move.fetch(:status).fetch('event_count'))
    baseline = execution.progress
    path = execution.instance_variable_get(:@storage).path
    bytes = File.binread(path)
    [nil, true, false, 0, 0.0, '', [], {}, 'public'].each do |value|
      document = JSON.parse(bytes)
      document.fetch('native').fetch('cores').first['visibility'] = value
      malformed = JSON.generate(document)
      native_calls = []
      trace = TracePoint.new(:call) do |point|
        if point.defined_class == T::LocalFixedTeamNativeEndpoint && point.method_id == :initialize
          native_calls << point.method_id
        end
      end
      begin
        File.binwrite(path, malformed)
        trace.enable
        error = assert_raises(T::Publication::Invalid) { execution.progress }
        trace.disable
        assert_equal(:sandbox_corrupt, error.code)
        assert_equal([], native_calls, 'The confirmed private table must be checked before native replay')
        assert_equal(malformed.b, File.binread(path))
      ensure
        trace.disable
        File.binwrite(path, bytes)
      end
      checks += 1
    end
    assert_equal(baseline, execution.progress)
    assert_equal(bytes, File.binread(path))
    assert_equal(1, execution.local_game(action: :local_game_status).fetch(:status).fetch('event_count'))
  end
end
puts "PASS local native visibility: #{checks} mismatched values rejected before replay; actual first move and bytes retained"
