require_relative '../support/tournament_individual_execution'
include TournamentIndividualExecutionSupport

checks = 0
with_fixture(game: 'tic_tac_toe', names: %w[Alpha Beta], rematch: false) do |fixture|
  record = start_individual_match(fixture, intent_id: 'storage-native-metadata-binding')
  owner = record.dig('evidence', 'plan', 'matches').first.fetch('players').first.fetch('username')
  player = nil
  with_individual_execution(fixture, record, owner) do |execution|
    player = execution.local_game(action: :local_game_status).fetch(:status).fetch('current_player')
  end
  with_individual_execution(fixture, record, player) do |execution|
    status = execution.local_game(action: :local_game_status).fetch(:status)
    move = execution.local_game(action: :local_game_move, operation_id: 'metadata-binding-first-move',
      revision: status.fetch('revision'), move_selection: status.fetch('actions').first)
    assert_equal(:confirmed, move[:state], move.inspect)
    assert_equal(1, move.fetch(:status).fetch('event_count'))
    baseline = execution.progress
    path = execution.instance_variable_get(:@storage).path
    bytes = File.binread(path)
    core = JSON.parse(bytes).fetch('native').fetch('cores').first
    %w[metadata discovery_metadata].each do |container|
      fields = ['protocol'] + (core.fetch(container).keys - ['protocol'])
      fields.each do |field|
        [true, false, nil, 0, 0.0, '', [], {}].each do |value|
          next if value.eql?(core.fetch(container).fetch(field))
          document = JSON.parse(bytes)
          document.fetch('native').fetch('cores').first.fetch(container)[field] = value
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
            assert_equal([], native_calls, 'Metadata must match the verified target before opening the native replay')
            assert_equal(malformed.b, File.binread(path), 'A refusal must not repair or rewrite the stored metadata')
          ensure
            trace.disable
            File.binwrite(path, bytes)
          end
          checks += 1
        end
      end
    end
    assert_equal(baseline, execution.progress)
    assert_equal(bytes, File.binread(path))
    assert_equal(1, execution.local_game(action: :local_game_status).fetch(:status).fetch('event_count'))
  end
end
puts "PASS local native metadata binding: #{checks} mismatched fields rejected before replay, real first move and original bytes retained"
