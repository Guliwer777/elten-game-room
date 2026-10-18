require_relative '../support/tournament_dispatch'
include TournamentDispatchSupport

names = %w[Organizator Beta Charlie Delta]
checks = 0
with_fixture(game: 'tic_tac_toe', names: names, rematch: false,
    group_advancement: T::GroupAdvancement::AUTOMATIC) do |fixture|
  backend = fixture.backend
  snapshot = lambda do
    Dir.glob(File.join(fixture.directory, '**', '*.json')).sort.to_h { |path| [path, File.binread(path)] }
  end
  unselected = T::LocalIndividualExecution.new(plan_backend: backend,
    plan_directory: File.join(fixture.directory, 'k02'), source_identity: fixture.tables.backend_identity,
    context: fixture.context, registry: fixture.registry, clock: -> { fixture.now },
    policy_ref: 'individual-technical-test-v1', expires_at: nil)
  before = snapshot.call
  error = assert_raises(T::Publication::Invalid) { unselected.knockout_execution_readback }
  assert_equal(:missing_selection, error.code)
  assert_equal(before, snapshot.call, 'Unselected readback must not change durable local JSON')
  parent = backend.accept(preview: backend.preview(publication_ref: fixture.reference,
    base_seats: fixture.base, intent_id: 'facade-shape-parent'))
  intent = parent['preview']['intent_id']
  fixture.now = parent['evidence']['plan']['matches'].first['windows'].first['opens'] + 1
  with_dispatch(fixture, parent, 'Organizator') { |dispatcher| dispatcher.configure(intent_id: intent, max_tables: 2) }
  names.each { |actor| with_dispatch(fixture, parent, actor) { |dispatcher| dispatcher.available(intent_id: intent, available: true) } }
  2.times { names.each { |actor| with_dispatch(fixture, parent, actor) { |dispatcher| dispatcher.advance(intent_id: intent) } } }
  names.each { |actor| with_dispatch(fixture, parent, actor) { |dispatcher| assert_equal(:confirmed, dispatcher.accept(intent_id: intent)[:state]) } }
  names.each { |actor| with_dispatch(fixture, parent, actor) { |dispatcher| dispatcher.advance(intent_id: intent) } }
  started = dispatch_state(fixture)['executions'].values.select { |execution| execution['start'] }
  assert_equal(2, started.size)
  started.each { |execution| finish_dispatch_board(fixture, parent, execution) }

  child = nil
  with_individual_execution(fixture, parent, 'Organizator') do |execution|
    sports = execution.knockout_preview
    assert_equal(:confirmed, sports[:state])
    assert_equal(:confirmed, execution.knockout_accept(preview: sports[:preview])[:state])
    generated = execution.knockout_execution_preview
    assert_equal(:confirmed, generated[:state])
    shown = generated[:preview]
    before = snapshot.call
    [nil, true, false, 0, 0.0, 'bad', [], {}].each do |value|
      [value, JSON.parse(JSON.generate(shown)).merge('source' => value)].each do |input|
        input_before = JSON.generate(input)
        assert_raises(T::Publication::Invalid) { execution.knockout_execution_accept(preview: input) }
        assert_equal(input_before, JSON.generate(input), 'Rejected preview must remain unchanged')
        assert_equal(before, snapshot.call, 'Rejected preview must not change any durable local JSON')
        checks += 1
      end
    end
    # Structurally valid but stale lineage still goes through the existing check.
    stale = JSON.parse(JSON.generate(shown))
    stale['source']['knockout_parent_intent'] = 'different-parent'
    error = assert_raises(T::Publication::Invalid) { execution.knockout_execution_accept(preview: stale) }
    assert_equal(:phase_changed, error.code)
    assert_equal(before, snapshot.call)
    child = execution.knockout_execution_accept(preview: shown)
    assert_equal(:confirmed, child[:state])
    assert_equal(child, execution.knockout_execution_accept(preview: shown), 'Same valid intent remains idempotent')
  end
  with_individual_execution(fixture, parent, 'Organizator') do |execution|
    assert_equal(child, execution.knockout_execution_readback, 'New execution instance must read the accepted child')
  end
  assert_equal(parent, fixture.backend(context: nil).readback(intent_id: intent))
end
puts "PASS local phase execution facade: #{checks} malformed previews refused; actual completed games, unchanged files, valid/idempotent acceptance and cold readback"
