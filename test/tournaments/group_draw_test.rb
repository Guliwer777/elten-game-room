require_relative '../support/tournament_dispatch'
include TournamentDispatchSupport
names = %w[Organizator Beta Charlie Delta]
draw = [[0,0],[0,1],[0,2],[1,1],[1,0],[1,2],[2,1],[2,0],[2,2]]
with_fixture(game: 'tic_tac_toe', names: names, rematch: false, group_advancement: T::GroupAdvancement::AUTOMATIC) do |fixture|
  backend = fixture.backend
  record = backend.accept(preview: backend.preview(publication_ref: fixture.reference, base_seats: fixture.base, intent_id: 'group-draw'))
  intent = record['preview']['intent_id']
  fixture.now = record['evidence']['plan']['matches'].first['windows'].first['opens'] + 1
  with_dispatch(fixture, record, names.first) { |d| d.configure(intent_id: intent, max_tables: 2) }
  names.each { |actor| with_dispatch(fixture, record, actor) { |d| d.available(intent_id: intent, available: true) } }
  2.times { names.each { |actor| with_dispatch(fixture, record, actor) { |d| d.advance(intent_id: intent) } } }
  names.each { |actor| with_dispatch(fixture, record, actor) { |d| assert_equal(:confirmed, d.accept(intent_id: intent)[:state]) } }
  names.each { |actor| with_dispatch(fixture, record, actor) { |d| d.advance(intent_id: intent) } }
  boards = dispatch_state(fixture)['executions'].values.select { |row| row['start'] }
  assert_equal(2, boards.size)
  boards.each { |board| finish_dispatch_board(fixture, record, board, moves: draw) }
  with_individual_execution(fixture, record, names.first) do |e|
    progress = e.progress
    assert_equal([1, 1, 1, 1], progress['standings'].map { |row| row['points'] })
    assert_equal([1, 1, 1, 1], progress['standings'].map { |row| row['draws'] })
    assert_equal(nil, progress['knockout_state'])
    shown = e.knockout_preview
    assert_equal(:confirmed, shown[:state])
    assert_equal(2, shown[:plan]['matches'].size)
    assert(shown[:plan]['qualification'], 'Missing explicit group-position tiebreak preview')
  end
  names.each { |actor| with_dispatch(fixture, record, actor) { |d| d.advance(intent_id: intent) } }
  assert_equal(2, dispatch_state(fixture)['executions'].size)
  assert_equal({}, dispatch_state(fixture)['busy'])
  assert_equal(1, fixture.backend(context: nil).accepted_records.size)
end
puts 'PASS group draws: one point each, no automatic replay of group games, explicit position tiebreak preview, no invented seeding'
