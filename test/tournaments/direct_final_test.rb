require_relative '../support/tournament_dispatch'
include TournamentDispatchSupport
names = %w[Organizator Beta]
with_fixture(game: 'tic_tac_toe', names: names, rematch: true, group_advancement: T::GroupAdvancement::AUTOMATIC) do |fixture|
  backend = fixture.backend
  shown = backend.preview(publication_ref: fixture.reference, base_seats: fixture.base, intent_id: 'direct-final')
  candidate = shown['source']['candidate']
  assert_equal('knockout', candidate['format'])
  assert_equal('direct_final', candidate['knockout']['origin'])
  assert_equal(false, candidate['rematch'])
  assert_equal(1, candidate['matches'].size)
  record = backend.accept(preview: shown)
  intent = record['preview']['intent_id']
  fixture.now = record['evidence']['plan']['matches'].first['windows'].first['opens'] + 1
  with_dispatch(fixture, record, names.first) { |d| d.configure(intent_id: intent, max_tables: 2) }
  names.each { |actor| with_dispatch(fixture, record, actor) { |d| d.available(intent_id: intent, available: true) } }
  2.times { names.each { |actor| with_dispatch(fixture, record, actor) { |d| d.advance(intent_id: intent) } } }
  names.each { |actor| with_dispatch(fixture, record, actor) { |d| assert_equal(:confirmed, d.accept(intent_id: intent)[:state]) } }
  names.each { |actor| with_dispatch(fixture, record, actor) { |d| d.advance(intent_id: intent) } }
  boards = dispatch_state(fixture)['executions'].values.select { |row| row['start'] }
  assert_equal(1, boards.size)
  finish_dispatch_board(fixture, record, boards.first)
  with_individual_execution(fixture, record, names.first) do |e|
    assert_equal('completed', e.progress['knockout_state'])
    assert_equal('organizator', e.progress['champion'])
    assert_equal(:tournament_completed, e.knockout_preview[:reason])
  end
  assert_equal({}, dispatch_state(fixture)['busy'])
  completed_state = dispatch_state(fixture)
  names.each do |actor|
    with_dispatch(fixture, record, actor) do |d|
      assert_equal(:matches_completed, d.advance(intent_id: intent)[:reason])
    end
  end
  assert_equal(completed_state, dispatch_state(fixture))
  assert_equal(record, fixture.backend(context: nil).readback(intent_id: intent))
end
puts 'PASS direct final: automatic two-player tournament, real invitations and Runner result, champion and cold readback'
