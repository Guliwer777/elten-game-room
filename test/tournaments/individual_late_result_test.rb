require_relative '../support/tournament_dispatch'
include TournamentDispatchSupport
[false, true].each do |complete_game|
  with_fixture(game: 'tic_tac_toe', names: %w[Alpha Beta], rematch: false) do |fixture|
    backend = fixture.backend
    record = backend.accept(preview: backend.preview(publication_ref: fixture.reference, base_seats: fixture.base, intent_id: 'late-result'))
    intent = record['preview']['intent_id']
    window = record['evidence']['plan']['matches'].first['windows'].first
    fixture.now = window['opens'] + 1
    with_dispatch(fixture, record, 'Organizator') { |d| d.configure(intent_id: intent, max_tables: 1) }
    %w[Alpha Beta].each { |actor| with_dispatch(fixture, record, actor) { |d| d.available(intent_id: intent, available: true) } }
    2.times { %w[Alpha Beta].each { |actor| with_dispatch(fixture, record, actor) { |d| d.advance(intent_id: intent) } } }
    %w[Alpha Beta].each { |actor| with_dispatch(fixture, record, actor) { |d| assert_equal(:confirmed, d.accept(intent_id: intent)[:state]) } }
    %w[Alpha Beta].each { |actor| with_dispatch(fixture, record, actor) { |d| d.advance(intent_id: intent) } }
    row = dispatch_state(fixture)['executions'].values.find { |value| value['start'] }
    moves = complete_game ? [[0,0],[1,0],[0,1],[1,1],[0,2]] : [[0,0],[1,0]]
    play_dispatch_board(fixture, record, row, moves: moves, clock: -> { fixture.now })
    before = dispatch_state(fixture)
    assert_equal(2, before['busy'].size)
    assert_equal(nil, before['executions'].values.first['result'])
    fixture.now = window['closes'] + 1
    with_individual_execution(fixture, record, row['coordinator'], clock: -> { fixture.now }) do |execution|
      status = execution.local_game(action: :local_game_status)[:status]
      result = execution.local_game(action: :finalize_local_game, revision: status['revision'])
      if complete_game
        assert_equal(:confirmed, result[:state], result.inspect)
        assert_equal(true, execution.progress['complete'])
        assert_equal([2, 0], execution.progress['standings'].map { |unit| unit['points'] })
      else
        assert_equal(:game_not_finished, result[:reason])
        assert_equal(false, execution.progress['complete'])
        assert_equal([0, 0], execution.progress['standings'].map { |unit| unit['points'] })
      end
    end
    after = dispatch_state(fixture)
    assert_equal(before['executions'].values.first['moves'], after['executions'].values.first['moves'])
    assert_equal(before['native']['creates'], after['native']['creates'])
    assert_equal(complete_game ? {} : before['busy'], after['busy'])
    assert_equal(before, after) unless complete_game
    assert_equal(record, fixture.backend(context: nil).readback(intent_id: intent))
  end
end
puts 'PASS expired match window: actual finished game can commit its result late; unfinished game gets no points, no duplicate table and retains reservations/history'
