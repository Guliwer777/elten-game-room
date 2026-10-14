require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/tournament_dispatch'
include TournamentDispatchSupport
with_fixture(game: 'tic_tac_toe', names: %w[Alpha Beta], rematch: true,
  group_advancement: T::GroupAdvancement::COMPACT, knockout_rematch: false, final_rematch: true) do |fixture|
  backend = fixture.backend
  record = backend.accept(preview: backend.preview(publication_ref: fixture.reference, base_seats: fixture.base, intent_id: 'return-final'))
  matches = record['evidence']['plan']['matches']
  fixture.now = matches.first['windows'].first['opens'] + 1
  assert_equal([1,2], matches.map { |match| match['leg'] })
  assert_equal(2, matches.map { |match| match['match_id'] }.uniq.size)
  assert_equal(true, record['preview']['source']['candidate']['rematch'])
  with_dispatch(fixture, record, 'Organizator') { |d| d.configure(intent_id: 'return-final', max_tables: 3) }
  %w[Alpha Beta].each { |actor| with_dispatch(fixture, record, actor) { |d| d.available(intent_id: 'return-final', available: true) } }
  2.times do |leg|
    2.times { %w[Alpha Beta].each { |actor| with_dispatch(fixture, record, actor) { |d| d.advance(intent_id: 'return-final') } } }
    %w[Alpha Beta].each { |actor| with_dispatch(fixture, record, actor) { |d| assert_equal(:confirmed, d.accept(intent_id: 'return-final')[:state]) } }
    %w[Alpha Beta].each { |actor| with_dispatch(fixture, record, actor) { |d| d.advance(intent_id: 'return-final') } }
    row = dispatch_state(fixture)['executions'].values.find { |r| r['start'] && !r['result'] }
    assert(row, 'Missing playable return leg')
    finish_dispatch_board(fixture, record, row)
    with_individual_execution(fixture, record, 'Organizator') do |e|
      progress = e.progress
      assert_equal(leg == 0 ? 'awaiting_results' : 'tie_requires_resolution', progress['knockout_state'])
    end
  end
  with_individual_execution(fixture, record, 'Organizator') do |e|
    shown = e.knockout_preview
    assert_equal(:confirmed, shown[:state], shown.inspect)
    assert_equal(1, shown[:plan]['replay']['attempt'])
    assert(!shown[:plan].key?('rematch'), 'Extra deciding game must be a single game')
    assert_equal(:confirmed, e.knockout_accept(preview: shown[:preview])[:state])
    next_plan = e.knockout_execution_preview
    assert_equal(:confirmed, next_plan[:state], next_plan.inspect)
    child = e.knockout_execution_accept(preview: next_plan[:preview])
    assert_equal(:confirmed, child[:state], child.inspect)
    assert_equal(1, child[:record]['evidence']['plan']['matches'].size)
  end
end
puts 'PASS real two-leg direct final: native games, waiting for second leg, aggregate draw and accepted extra game'
