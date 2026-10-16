require_relative '../support/tournament_dispatch'
include TournamentDispatchSupport
names = %w[Alpha Beta Charlie Delta]
automatic = ARGV.include?('--automatic')
settings = automatic ? {group_advancement: T::GroupAdvancement::AUTOMATIC} : {group_count: 2, places_per_group: 1}
with_fixture(game: 'tic_tac_toe', names: names, rematch: false, **settings) do |fixture|
  backend = fixture.backend
  preview = backend.preview(publication_ref: fixture.reference, base_seats: fixture.base, intent_id: 'group-dispatch')
  record = backend.accept(preview: preview)
  candidate = record['preview']['source']['candidate']
  assert_equal('groups_knockout', candidate['format'])
  assert_equal([%w[alpha charlie], %w[beta delta]], candidate['groups'].map { |group| group['units'] })
  assert_equal(2, record['evidence']['plan']['matches'].size)
  assert_equal(2, candidate['groups'].flat_map { |group| group['matches'] }.uniq.size)
  intent = record['preview']['intent_id']
  fixture.now = record['evidence']['plan']['matches'].first['windows'].first['opens'] + 1
  with_dispatch(fixture, record, 'Organizator') { |d| d.configure(intent_id: intent, max_tables: 2) }
  names.each { |actor| with_dispatch(fixture, record, actor) { |d| d.available(intent_id: intent, available: true) } }
  2.times { names.each { |actor| with_dispatch(fixture, record, actor) { |d| d.advance(intent_id: intent) } } }
  names.each { |actor| with_dispatch(fixture, record, actor) { |d| assert_equal(:confirmed, d.accept(intent_id: intent)[:state]) } }
  names.each { |actor| with_dispatch(fixture, record, actor) { |d| d.advance(intent_id: intent) } }
  state = dispatch_state(fixture)
  started = state['executions'].values.select { |row| row['start'] }
  assert_equal(2, started.size)
  assert_equal(4, state['busy'].size)
  started.each { |row| finish_dispatch_board(fixture, record, row) }
  state = dispatch_state(fixture)
  assert_equal({}, state['busy'])
  bytes = JSON.generate(state)
  names.each do |actor|
    with_individual_execution(fixture, record, actor) do |execution|
      progress = execution.progress
      assert_equal(automatic ? 'ready_knockout' : 'awaiting_seeding', progress['group_state'])
      assert_equal(2, progress['completed'])
      assert_equal(true, progress['complete'])
      assert_equal(automatic ? 4 : 2, progress['qualified'].size)
      if automatic
        phase = execution.knockout_preview(seeds: nil)
        assert_equal(:confirmed, phase[:state])
        assert_equal(progress['cross_seeding']['pairs'], phase[:plan]['matches'].map { |match| match['participants'] })
      end
      assert_equal(2, progress['standings'].count { |row| row['place'] == 1 })
      assert_equal([2, 2], progress['standings'].select { |row| row['place'] == 1 }.map { |row| row['points'] })
      assert_equal(%w[group-1 group-2], progress['standings'].map { |row| row['group'] }.uniq)
    end
  end
  assert_equal(bytes, JSON.generate(dispatch_state(fixture)))
  reopened = fixture.backend(context: nil).readback(intent_id: intent)
  assert_equal(record, reopened)
  damaged = Marshal.load(Marshal.dump(preview))
  damaged['source']['candidate']['groups'].first['units'] = %w[alpha beta]
  assert_raises(T::Publication::Invalid) { backend.accept(preview: damaged) }
end
puts 'PASS accepted groups: real publication/signup, two automatic tables, own entry, runner results and cold standings'
