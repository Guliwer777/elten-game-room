require_relative '../support/tournament_dispatch'
include TournamentDispatchSupport
names = %w[Alpha Beta Charlie Delta Echo Foxtrot]
with_fixture(game: 'tic_tac_toe', names: names, rematch: false) do |fixture|
  backend = fixture.backend
  record = backend.accept(preview: backend.preview(publication_ref: fixture.reference, base_seats: fixture.base, intent_id: 'automatic-dispatch'))
  intent = record['preview']['intent_id']
  fixture.now = record['evidence']['plan']['matches'].first['windows'].first['opens'] + 1
  with_dispatch(fixture, record, 'Organizator') { |d| assert_equal(2, d.configure(intent_id: intent, max_tables: 2)) }
  with_dispatch(fixture, record, 'Alpha') do |d|
    assert_raises(T::CoordinationContract::Blocked) { d.configure(intent_id: intent, max_tables: 3) }
    assert_equal([], d.snapshot(intent_id: intent)['candidates'])
    assert_equal(:participants_unavailable, d.advance(intent_id: intent)[:reason])
    fixture.now = record['evidence']['plan']['matches'].first['windows'].first['opens'] - 1
    assert_equal(:match_window_not_open, d.advance(intent_id: intent)[:reason])
    fixture.now = record['evidence']['plan']['matches'].first['windows'].first['closes']
    assert_equal(:match_window_closed, d.advance(intent_id: intent)[:reason])
    fixture.now = record['evidence']['plan']['matches'].first['windows'].first['opens'] + 1
    assert_raises(T::CoordinationContract::Blocked) { d.accept(intent_id: intent) }
  end
  names.each { |name| with_dispatch(fixture, record, name) { |d| d.available(intent_id: intent, available: true) } }
  with_dispatch(fixture, record, 'Alpha') do |d|
    rows = d.snapshot(intent_id: intent)['candidates']
    assert_equal(2, rows.size)
    assert_equal(rows.flat_map { |row| row['players'] }.uniq.size, rows.sum { |row| row['players'].size })
  end
  2.times { names.each { |name| with_dispatch(fixture, record, name) { |d| d.advance(intent_id: intent) } } }
  state = dispatch_state(fixture)
  assert_equal(2, state['native']['cores'].size)
  assert_equal(4, state['busy'].size)
  assert_equal(2, state['native']['cores'].sum { |core| core['invitations'].size })
  state['native']['cores'].each { |core| assert_equal(1, core['participants'].size) }
  bytes = JSON.generate(state)
  with_dispatch(fixture, record, 'Echo') do |d|
    assert_equal(:table_limit, d.advance(intent_id: intent)[:reason])
  end
  assert_equal(bytes, JSON.generate(dispatch_state(fixture)))
  2.times { names.each { |name| with_dispatch(fixture, record, name) { |d| d.advance(intent_id: intent) } } }
  assert_equal(bytes, JSON.generate(dispatch_state(fixture)))
  unused = record['evidence']['plan']['matches'].find { |match| match['leg'] == 1 && match['players'].map { |person| person['account'] }.sort == %w[echo foxtrot] }
  %w[Echo Foxtrot].each do |name|
    with_individual_execution(fixture, record, name) do |execution|
      execution.select(intent_id: intent, match_id: unused['match_id'], leg: unused['leg'], window_id: unused['windows'].first['id'])
      assert_equal(:confirmed, execution.declare(availability: 'ready', expected_revision: 0)[:state])
      assert_equal(:table_limit, execution.request_match[:reason]) if name == 'Foxtrot'
    end
  end
  with_dispatch(fixture, record, 'Organizator') { |d| d.configure(intent_id: intent, max_tables: 3) }
  2.times { names.each { |name| with_dispatch(fixture, record, name) { |d| d.advance(intent_id: intent) } } }
  state = dispatch_state(fixture)
  assert_equal(3, state['native']['cores'].size)
  assert_equal(6, state['busy'].size)
  assert_equal(3, state['native']['cores'].sum { |core| core['invitations'].size })
  names.each { |name| with_dispatch(fixture, record, name) { |d| assert_equal(:confirmed, d.accept(intent_id: intent)[:state]) } }
  names.each { |name| with_dispatch(fixture, record, name) { |d| d.advance(intent_id: intent) } }
  state = dispatch_state(fixture)
  assert_equal(3, state['executions'].values.count { |row| row['start'] })
  assert_equal(3, state['native']['creates'].size)
  assert(state['native']['cores'].all? { |core| core['participants'].size == 2 }, 'Only accepted invitations may admit players')
  completed = state['executions'].values.select { |row| row['start'] }.first(2)
  completed.each { |row| finish_dispatch_board(fixture, record, row) }
  assert_equal(2, dispatch_state(fixture)['busy'].size)
  with_dispatch(fixture, record, 'Alpha') do |d|
    assert_equal(2, d.snapshot(intent_id: intent)['candidates'].size)
  end
  2.times { names.each { |name| with_dispatch(fixture, record, name) { |d| d.advance(intent_id: intent) } } }
  state = dispatch_state(fixture)
  assert_equal(5, state['native']['creates'].size)
  assert_equal(6, state['busy'].size)
  assert_equal(2, state['executions'].values.count { |row| row['result'] })
  fixture.now += T::LocalDispatchContract::TTL
  with_dispatch(fixture, record, 'Alpha') do |d|
    assert_equal([], d.snapshot(intent_id: intent)['candidates'])
    assert_equal(:blocked, d.advance(intent_id: intent)[:state])
  end
  assert_equal(6, dispatch_state(fixture)['busy'].size)
end
puts 'PASS automatic local tournament dispatch: 2/3 distinct native tables, only available players, own readiness, automatic invitations, no fabricated consent, table limit, retries and stale availability'
