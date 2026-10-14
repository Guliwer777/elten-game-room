require_relative '../support/tournament_dice_execution'
include TournamentDiceExecutionSupport
$stdout.sync = true
# Isolated test oracle; all moves and recorded randomness use the real Runner.
GameRoomRandom::LocalSecureSource.prepend(Module.new do
  def roll(count:, sides:)
    raise 'unexpected dice request' unless count == 6 && sides == 6
    GameRoomRandom::Roll.new(values: [1,2,3,4,5,6], sides: sides, source: source_name, proof: nil)
  end
end)
names = %w[Alpha Beta Gamma]
with_fixture(game: 'farkle', names: names, players_per_match: 3, rematch: true,
  game_options: {'score_limit' => 200, 'turn_minimum' => 0, 'entry_minimum' => 0, 'farkle_rules_version' => 2}) do |fixture|
  backend = fixture.backend
  record = backend.accept(preview: backend.preview(publication_ref: fixture.reference,
    base_seats: fixture.base, intent_id: 'three-seat-rematch'))
  intent = record['preview']['intent_id']
  fixture.now = record['evidence']['plan']['matches'].first['windows'].first['opens'] + 1
  with_dispatch(fixture, record, 'Organizator') { |d| d.configure(intent_id: intent, max_tables: 1) }
  names.each { |actor| with_dispatch(fixture, record, actor) { |d| d.available(intent_id: intent, available: true) } }
  first_seats = nil
  first_history = nil
  2.times do |leg|
    2.times { names.each { |actor| with_dispatch(fixture, record, actor) { |d| d.advance(intent_id: intent) } } }
    state = dispatch_state(fixture)
    assert_equal(leg + 1, state['native']['creates'].size)
    assert_equal(3, state['busy'].size)
    names.each { |actor| with_dispatch(fixture, record, actor) { |d| assert_equal(:confirmed, d.accept(intent_id: intent)[:state]) } }
    names.each { |actor| with_dispatch(fixture, record, actor) { |d| d.advance(intent_id: intent) } }
    row = dispatch_state(fixture)['executions'].values.find { |execution| execution['request']['leg'] == leg + 1 }
    seats = row['request']['players'].sort_by { |person| person['seat'] }.map { |person| person['account'] }
    if leg.zero?
      first_seats = seats
      assert_equal(1, dispatch_state(fixture)['executions'].size, 'Return match must wait for a real first result')
    else
      assert_equal(first_seats.reverse, seats)
    end
    finish_dispatch_farkle(fixture, record, row)
    state = dispatch_state(fixture)
    assert_equal({}, state['busy'])
    if leg.zero?
      first_history = state['executions'].values.first
    else
      assert_equal(first_history, state['executions'].values.find { |execution| execution['request']['leg'] == 1 })
    end
    puts "PASS real three-player leg #{leg + 1} completed"
  end
  with_individual_execution(fixture, record, 'Alpha') do |execution|
    assert_equal(true, execution.progress['complete'])
    assert_equal([2, 2, 2], execution.progress['standings'].map { |row| row['points'] })
    assert_equal([400, 400, 400], execution.progress['standings'].map { |row| row['score_for'] })
  end
  assert_equal(record, fixture.backend(context: nil).readback(intent_id: intent))
end
puts 'PASS automatic three-player return match: first true result unlocks new invitations, reversed seats, two real finishes, cumulative points/scores and immutable first history'
