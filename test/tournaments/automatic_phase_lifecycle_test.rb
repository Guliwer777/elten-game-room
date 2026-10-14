require_relative '../support/tournament_phase_connection'
include TournamentPhaseConnectionSupport
with_fixture(game: 'tic_tac_toe', names: %w[Alpha Beta Gamma Delta], rematch: false,
  group_advancement: T::GroupAdvancement::AUTOMATIC) do |fixture|
  backend = fixture.backend
  root = backend.accept(preview: backend.preview(publication_ref: fixture.reference, base_seats: fixture.base, intent_id: 'automatic-phases'))
  roots = [root['preview']['intent_id']]
  records = [root]
  fixture.now = root['evidence']['plan']['matches'].first['windows'].first['opens'] + 1
  3.times do |round|
    record = records.last
    intent = record['preview']['intent_id']
    with_phase_connection(fixture, 'Organizator') do |connection|
      outcome = connection.advance_tournament(publication_ref: fixture.reference, root_intents: roots)
      assert_equal(:blocked, outcome[:transitions].first[:state])
    end
    with_dispatch(fixture, record, 'Organizator') { |d| d.configure(intent_id: intent, max_tables: 3) }
    people = record['evidence']['plan']['matches'].flat_map { |match| match['players'].map { |person| person['username'] } }.uniq
    people.each { |actor| with_dispatch(fixture, record, actor) { |d| d.available(intent_id: intent, available: true) } }
    2.times { people.each { |actor| with_dispatch(fixture, record, actor) { |d| d.advance(intent_id: intent) } } }
    people.each { |actor| with_dispatch(fixture, record, actor) { |d| assert_equal(:confirmed, d.accept(intent_id: intent)[:state]) } }
    people.each { |actor| with_dispatch(fixture, record, actor) { |d| d.advance(intent_id: intent) } }
    boards = dispatch_state(fixture)['executions'].values.select { |row| row['record_intent'] == intent && row['start'] }
    assert_equal(round == 2 ? 1 : 2, boards.size)
    boards.each do |row|
      finish_dispatch_board(fixture, record, row, finalize: false)
      with_dispatch(fixture, record, row['coordinator']) { |d| assert_equal(:confirmed, d.advance(intent_id: intent)[:state]) }
    end
    assert_equal({}, dispatch_state(fixture)['busy'])
    with_phase_connection(fixture, 'Observer') do |connection|
      assert_equal([], connection.advance_tournament(publication_ref: fixture.reference, root_intents: roots)[:transitions])
    end
    2.times do
      with_phase_connection(fixture, 'Organizator') do |connection|
        outcome = connection.advance_tournament(publication_ref: fixture.reference, root_intents: roots)
        rows = connection.tournament_branch_catalog(publication_ref: fixture.reference, root_intents: roots)
        assert_equal(round == 2 ? 3 : round + 2, rows.size)
        if round == 2
          assert_equal(:tournament_completed, outcome[:transitions].first[:reason])
          assert(rows.any? { |item| item['progress']['champion'] }, 'Missing final champion')
        elsif records.size == round + 1
          records << outcome[:transitions].first.fetch(:record)
        end
      end
    end
  end
  records.each { |record| assert_equal(record, fixture.backend(context: nil).readback(intent_id: record['preview']['intent_id'])) }
end
puts 'PASS automatic groups, semifinals, final, cold reopening, one child per parent and observer cannot approve'
