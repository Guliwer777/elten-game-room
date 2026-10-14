require_relative '../support/tournament_dispatch'
include TournamentDispatchSupport

[:preparing, :playing, :finished].each do |phase|
  with_fixture(game: 'tic_tac_toe', names: %w[Alpha Beta], rematch: false) do |fixture|
    backend = fixture.backend
    record = backend.accept(preview: backend.preview(publication_ref: fixture.reference,
      base_seats: fixture.base, intent_id: "deadline-#{phase}"))
    intent = record['preview']['intent_id']
    window = record['evidence']['plan']['matches'].first['windows'].first
    fixture.now = window['opens'] + 1
    with_dispatch(fixture, record, 'Organizator') { |d| d.configure(intent_id: intent, max_tables: 1) }
    %w[Alpha Beta].each { |name| with_dispatch(fixture, record, name) { |d| d.available(intent_id: intent, available: true) } }
    2.times { %w[Alpha Beta].each { |name| with_dispatch(fixture, record, name) { |d| d.advance(intent_id: intent) } } }
    unless phase == :preparing
      %w[Alpha Beta].each { |name| with_dispatch(fixture, record, name) { |d| assert_equal(:confirmed, d.accept(intent_id: intent)[:state]) } }
      with_dispatch(fixture, record, 'Alpha') { |d| assert_equal(:confirmed, d.advance(intent_id: intent)[:state]) }
    end
    row = dispatch_state(fixture)['executions'].values.first
    play_dispatch_board(fixture, record, row, moves: [[0,0],[1,0],[0,1],[1,1],[0,2]]) if phase == :finished
    path = File.join(fixture.directory, 'k02/individual-v1/execution-v1/state.json')
    before = File.binread(path)
    fixture.now = window['closes']
    %w[Alpha Beta].each do |name|
      with_dispatch(fixture, record, name) do |d|
        active = d.snapshot(intent_id: intent)['active'].first
        assert_equal(phase != :finished, active['interrupted'])
        if phase != :finished
          effect = d.advance(intent_id: intent)
          assert_equal(:blocked, effect[:state])
          assert_equal(:execution_interrupted, effect[:reason])
        end
      end
    end
    assert_equal(before, File.binread(path))
    assert_equal(2, dispatch_state(fixture)['busy'].size)
    assert(dispatch_state(fixture)['executions'].values.all? { |value| !value['result'] }, 'Expiry must not invent a result')
    if phase == :finished
      with_individual_execution(fixture, record, row['coordinator'], clock: -> { fixture.now }) do |execution|
        request = row['request']
        execution.select(intent_id: intent, match_id: request['match_id'], leg: request['leg'], window_id: request['window']['id'])
        status = execution.local_game(action: :local_game_status)[:status]
        assert_equal('finished', status['phase'])
        result = execution.local_game(action: :finalize_local_game, revision: status['revision'])
        assert_equal(:confirmed, result[:state], result.inspect)
        assert_equal(result[:effect], execution.local_game(action: :finalize_local_game, revision: status['revision'])[:effect])
      end
      state = dispatch_state(fixture)
      assert_equal({}, state['busy'])
      assert_equal(1, state['executions'].values.count { |value| value['result'] })
      with_individual_execution(fixture, record, row['coordinator'], clock: -> { fixture.now }) do |execution|
        progress = execution.progress
        assert_equal(1, progress['completed'])
        assert_equal([0, 2], progress['standings'].map { |value| value['points'] }.sort)
      end
    end
  end
end
puts 'PASS dispatch deadlines: no invented result; finished replay finalized once after expiry, reservations released and standings restored'
