require_relative '../support/tournament_dice_execution'
include TournamentDiceExecutionSupport
$stdout.sync = true
finish = ARGV.include?('--finish')
if finish
  # Only this test process supplies known fresh dice; ordinary Runner receipts
  # record the rolls and replay validates them without drawing replacements.
  GameRoomRandom::LocalSecureSource.prepend(Module.new do
    def roll(count:, sides:)
      raise 'unexpected dice request' unless count == 6 && sides == 6
      GameRoomRandom::Roll.new(values: [1,2,3,4,5,6], sides: sides, source: source_name, proof: nil)
    end
  end)
end
future = Class.new(finish ? GameRoomGames::Farkle : GameRoomGames::Categories) do
  def id; 'future_multi_seat'; end
end
names = %w[Alpha Beta Gamma Delta Echo Foxtrot]
with_fixture(game: 'future_multi_seat', registry: GameRoomGames::Registry.new([future]),
  names: names, players_per_match: 3, rematch: false,
  game_options: finish ? {'score_limit' => 200, 'turn_minimum' => 0, 'entry_minimum' => 0, 'farkle_rules_version' => 2} : nil) do |fixture|
  backend = fixture.backend
  record = backend.accept(preview: backend.preview(publication_ref: fixture.reference,
    base_seats: fixture.base, intent_id: 'automatic-three-seat'))
  intent = record['preview']['intent_id']
  fixture.now = record['evidence']['plan']['matches'].first['windows'].first['opens'] + 1
  with_dispatch(fixture, record, 'Organizator') { |d| d.configure(intent_id: intent, max_tables: 2) }
  names.first(2).each { |actor| with_dispatch(fixture, record, actor) { |d| d.available(intent_id: intent, available: true) } }
  names.first(2).each do |actor|
    with_dispatch(fixture, record, actor) do |d|
      assert_equal([], d.snapshot(intent_id: intent)['candidates'])
      assert_equal(:participants_unavailable, d.advance(intent_id: intent)[:reason])
    end
  end
  assert_equal(0, Array(dispatch_state(fixture).dig('native', 'cores')).size)
  names.each { |actor| with_dispatch(fixture, record, actor) { |d| d.available(intent_id: intent, available: true) } }
  2.times { names.each { |actor| with_dispatch(fixture, record, actor) { |d| d.advance(intent_id: intent) } } }
  state = dispatch_state(fixture)
  assert_equal(2, state['native']['cores'].size)
  assert_equal(6, state['busy'].size)
  assert_equal(4, state['native']['cores'].sum { |core| core['invitations'].size })
  assert_equal([1, 1], state['native']['cores'].map { |core| core['participants'].size })
  assert_equal(0, state['executions'].values.count { |row| row['start'] })
  reserved = state['executions'].values.map { |row| row['request']['players'].map { |person| person['account'] } }
  assert_equal([3, 3], reserved.map(&:size))
  assert_equal(names.map(&:downcase).sort, reserved.flatten.sort)
  bytes = JSON.generate(state)
  names.each { |actor| with_dispatch(fixture, record, actor) { |d| d.advance(intent_id: intent) } }
  assert_equal(bytes, JSON.generate(dispatch_state(fixture)))
  names.each { |actor| with_dispatch(fixture, record, actor) { |d| assert_equal(:confirmed, d.accept(intent_id: intent)[:state]) } }
  names.each { |actor| with_dispatch(fixture, record, actor) { |d| d.advance(intent_id: intent) } }
  state = dispatch_state(fixture)
  assert_equal(2, state['native']['creates'].size)
  assert_equal([3, 3], state['native']['cores'].map { |core| core['participants'].size })
  assert_equal(2, state['executions'].values.count { |row| row['start'] })
  assert_equal(0, state['executions'].values.count { |row| row['result'] })
  names.each { |actor| with_dispatch(fixture, record, actor) { |d| d.advance(intent_id: intent) } }
  assert_equal(state, dispatch_state(fixture))
  assert_equal(record, fixture.backend(context: nil).readback(intent_id: intent))
  if finish
    state['executions'].values.each do |row|
      finish_dispatch_farkle(fixture, record, row)
      puts 'PASS one actual three-seat dice match completed'
    end
    final = dispatch_state(fixture)
    assert_equal({}, final['busy'])
    assert_equal(2, final['executions'].values.count { |row| row['result'] })
    assert_equal(2, final['native']['creates'].size)
    state['executions'].each { |key, row| assert_equal(row['start'], final['executions'].fetch(key)['start']) }
    with_individual_execution(fixture, record, names.first) do |execution|
      assert_equal(Array.new(6, 1), execution.progress['standings'].map { |row| row['points'] })
      assert_equal(Array.new(6, 200), execution.progress['standings'].map { |row| row['score_for'] })
    end
    assert_equal(record, fixture.backend(context: nil).readback(intent_id: intent))
    path = File.join(fixture.directory, 'k02/individual-v1/execution-v1/state.json')
    bytes = File.binread(path)
    probe = File.expand_path('../support/tournament_multi_seat_finish_probe.rb', __dir__)
    output = IO.popen([RbConfig.ruby, probe, fixture.directory], err: [:child, :out], &:read)
    assert($?.success?, output)
    assert_equal(bytes, File.binread(path))
  end
end
puts 'PASS generic automatic three-seat dispatch: future game without allowlist, two disjoint native tables, four invitations, explicit participant acceptance, exactly two Starts and no invented outcomes'
