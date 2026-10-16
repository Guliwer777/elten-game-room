require_relative '../support/binary_rules_load' if ARGV.first && !ARGV.first.start_with?('--')
require_relative '../support/tournament_phase_connection'
include TournamentPhaseConnectionSupport
with_fixture(game: 'tic_tac_toe', names: %w[Alpha Beta Charlie Delta Echo Foxtrot Golf Hotel India], rematch: false,
  group_advancement: T::GroupAdvancement::COMPACT) do |fixture|
  backend = fixture.backend
  root = backend.accept(preview: backend.preview(publication_ref: fixture.reference, base_seats: fixture.base, intent_id: 'group-tie-root'))
  fixture.now = root['evidence']['plan']['matches'].first['windows'].first['opens'] + 1
  root['evidence']['plan']['matches'].each_with_index do |match,index|
    with_individual_execution(fixture, root, 'Organizator') do |execution|
      execution.select_for_reconcile(intent_id: root['preview']['intent_id'], match_id: match['match_id'], leg: match['leg'], window_id: match['windows'].first['id'])
      status = execution.organizer_result_status
      winner = match['players'].map { |person| person['account'] }.min
      assert_equal(:confirmed, execution.organizer_forfeit(operation_id: "group-decision-#{index}", winner: winner, reason: 'Explicit local organizer test', expected_revision: status[:revision])[:state])
    end
  end
  roots = [root['preview']['intent_id']]
  child = nil
  with_phase_connection(fixture, 'Organizator') do |connection|
    result = connection.advance_tournament(publication_ref: fixture.reference, root_intents: roots)
    value = result[:transitions].first
    assert_equal(:confirmed, value[:state], value.inspect)
    child = value[:record]
    assert(child.dig('preview','source','candidate','knockout','qualification'), 'Missing accepted tiebreak lineage')
    assert_equal(3, child['evidence']['plan']['matches'].size)
  end
  if ARGV.include?('--real')
    intent = child['preview']['intent_id']
    names = child['evidence']['plan']['matches'].flat_map { |match| match['players'].map { |p| p['username'] } }.uniq
    with_dispatch(fixture, child, 'Organizator') { |d| d.configure(intent_id: intent, max_tables: 3) }
    names.each { |actor| with_dispatch(fixture, child, actor) { |d| d.available(intent_id: intent, available: true) } }
    3.times do
      2.times { names.each { |actor| with_dispatch(fixture, child, actor) { |d| d.advance(intent_id: intent) } } }
      row = dispatch_state(fixture)['executions'].values.find { |r| r['record_intent'] == intent && !r['result'] && r['target'] }
      assert(row, 'Missing extra-game table')
      actors = row['request']['players'].map { |p| p['username'] }
      actors.each { |actor| with_dispatch(fixture, child, actor) { |d| assert_equal(:confirmed, d.accept(intent_id: intent)[:state]) } }
      actors.each { |actor| with_dispatch(fixture, child, actor) { |d| d.advance(intent_id: intent) } }
      row = dispatch_state(fixture)['executions'].values.find { |r| r['record_intent'] == intent && !r['result'] && r['start'] }
      assert(row, 'Extra-game table did not start')
      finish_dispatch_board(fixture, child, row)
    end
  else
    child['evidence']['plan']['matches'].each_with_index do |match,index|
    with_individual_execution(fixture, child, 'Organizator') do |execution|
      execution.select_for_reconcile(intent_id: child['preview']['intent_id'], match_id: match['match_id'], leg: match['leg'], window_id: match['windows'].first['id'])
      status = execution.organizer_result_status
      winner = match['players'].map { |person| person['account'] }.min
      assert_equal(:confirmed, execution.organizer_forfeit(operation_id: "extra-decision-#{index}", winner: winner, reason: 'Explicit local organizer test', expected_revision: status[:revision])[:state])
    end
  end
  end
  with_phase_connection(fixture, 'Organizator') do |connection|
    value = connection.advance_tournament(publication_ref: fixture.reference, root_intents: roots)[:transitions].first
    assert_equal(:confirmed, value[:state], value.inspect)
    assert(!value[:record].dig('preview','source','candidate','knockout','qualification'), 'Did not leave qualification stage')
    assert_equal(4, value[:record]['preview']['source']['candidate']['roster'].size)
    assert_equal(2, value[:record]['evidence']['plan']['matches'].size)
    rows = connection.tournament_branch_catalog(publication_ref: fixture.reference, root_intents: roots)
    assert_equal(3, rows.size)
  end
  assert_equal(root, fixture.backend(context: nil).readback(intent_id: roots.first))
end
puts 'PASS accepted nine-player group tie: verified organizer results, three extra matches, fresh guarded phase, four semifinalists and immutable root'
