require_relative '../support/tournament_dispatch'
require 'timeout'
$stdout.sync = true
include TournamentDispatchSupport
if ARGV.include?('--uncertain')
  T::LocalExecutionPlanStorage.prepend(Module.new do
    def write(document)
      value = super
      if $knockout_after_replace_failure && path.include?('knockout-plans-v1')
        $knockout_after_replace_failure = false
        raise IOError, 'Injected failure after successful durable replacement'
      end
      value
    end
  end)
end
names = %w[Organizator Beta Charlie Delta]
with_fixture(game: 'tic_tac_toe', names: names, rematch: false, group_advancement: T::GroupAdvancement::AUTOMATIC) do |fixture|
  backend = fixture.backend
  record = backend.accept(preview: backend.preview(publication_ref: fixture.reference, base_seats: fixture.base, intent_id: 'phase-parent'))
  intent = record['preview']['intent_id']
  fixture.now = record['evidence']['plan']['matches'].first['windows'].first['opens'] + 1
  with_dispatch(fixture, record, 'Organizator') { |d| d.configure(intent_id: intent, max_tables: 2) }
  names.each { |actor| with_dispatch(fixture, record, actor) { |d| d.available(intent_id: intent, available: true) } }
  2.times { names.each { |actor| with_dispatch(fixture, record, actor) { |d| d.advance(intent_id: intent) } } }
  names.each { |actor| with_dispatch(fixture, record, actor) { |d| assert_equal(:confirmed, d.accept(intent_id: intent)[:state]) } }
  names.each { |actor| with_dispatch(fixture, record, actor) { |d| d.advance(intent_id: intent) } }
  started = dispatch_state(fixture)['executions'].values.select { |row| row['start'] }
  assert_equal(2, started.size)
  with_individual_execution(fixture, record, 'Organizator') do |e|
    assert_equal(:blocked, e.knockout_preview[:state])
    assert_equal(:unknown, e.knockout_readback[:state])
  end
  started.each { |row| finish_dispatch_board(fixture, record, row) }
  unchanged = JSON.generate(dispatch_state(fixture))
  preview = nil
  with_individual_execution(fixture, record, 'Organizator') do |e|
    effect = e.knockout_preview
    assert_equal(:confirmed, effect[:state])
    preview = effect[:preview]
    assert_equal(2, preview['receipts'].size)
    assert_equal(record['evidence']['plan_digest'], preview['parent']['plan_digest'])
  end
  with_individual_execution(fixture, record, 'Beta') do |e|
    assert_equal(:not_author, e.knockout_accept(preview: preview)[:reason])
  end
  accepted = nil
  with_individual_execution(fixture, record, 'Organizator') do |e|
    tampered = Marshal.load(Marshal.dump(preview))
    tampered['digest'] = '0' * 64
    assert_equal(:phase_changed, e.knockout_accept(preview: tampered)[:reason])
    tampered = Marshal.load(Marshal.dump(preview))
    tampered['plan']['round'] = 1.0
    assert_equal(:phase_changed, e.knockout_accept(preview: tampered)[:reason])
    $knockout_after_replace_failure = ARGV.include?('--uncertain')
    accepted = e.knockout_accept(preview: preview)
    if ARGV.include?('--uncertain')
      assert_equal(:uncertain, accepted[:state])
      assert_equal(preview['digest'], accepted[:digest])
      accepted = e.knockout_readback
    end
    assert_equal(:confirmed, accepted[:state])
    assert_equal(false, accepted[:record]['dispatch_allowed'])
    assert_equal(accepted, e.knockout_accept(preview: preview))
  end
  with_individual_execution(fixture, record, 'Organizator') do |e|
    assert_equal(accepted, e.knockout_readback)
  end
  assert_equal(unchanged, JSON.generate(dispatch_state(fixture)))
  assert_equal(record, fixture.backend(context: nil).readback(intent_id: intent))
  if ARGV.include?('--execute')
    phase_record = nil
    with_individual_execution(fixture, record, 'Organizator') do |_e, authority|
      phase_backend = fixture.backend(context: authority)
      shown = phase_backend.knockout_execution_preview(parent_intent: intent)
      phase_record = phase_backend.accept(preview: shown)
      assert_equal(record['preview']['result_policy'], phase_record['preview']['result_policy'])
      assert_equal(record['evidence']['source']['result_policy'], phase_record['evidence']['source']['result_policy'])
      assert_equal(phase_record, phase_backend.accept(preview: shown))
      assert_equal(preview['plan']['matches'].map { |m| m['participants'] },
        phase_record['preview']['source']['candidate']['matches'].map { |m| m['players'] })
    end
    phase_intent = phase_record['preview']['intent_id']
    assert_equal(phase_record, fixture.backend(context: nil).readback(intent_id: phase_intent))
    assert_equal(record, fixture.backend(context: nil).readback(intent_id: intent))
    with_dispatch(fixture, phase_record, 'Organizator') { |d| d.configure(intent_id: phase_intent, max_tables: 2) }
    names.each { |actor| with_dispatch(fixture, phase_record, actor) { |d| d.available(intent_id: phase_intent, available: true) } }
    2.times { names.each { |actor| with_dispatch(fixture, phase_record, actor) { |d| d.advance(intent_id: phase_intent) } } }
    names.each { |actor| with_dispatch(fixture, phase_record, actor) { |d| assert_equal(:confirmed, d.accept(intent_id: phase_intent)[:state]) } }
    names.each { |actor| with_dispatch(fixture, phase_record, actor) { |d| d.advance(intent_id: phase_intent) } }
    boards = dispatch_state(fixture)['executions'].values.select { |row| row['record_intent'] == phase_intent && row['start'] }
    assert_equal(2, boards.size)
    assert_equal(4, dispatch_state(fixture)['busy'].size)
    if ARGV.include?('--draw-semifinal')
      decisive, tied = boards
      carried_winner = decisive['request']['players'].min_by { |person| person['seat'] }['account']
      tied_players = tied['request']['players'].sort_by { |person| person['seat'] }.map { |person| person['account'] }
      finish_dispatch_board(fixture, phase_record, decisive)
      finish_dispatch_board(fixture, phase_record, tied,
        moves: [[0,0],[0,1],[0,2],[1,1],[1,0],[1,2],[2,1],[2,0],[2,2]])
      original_phase = phase_record
      original_state = dispatch_state(fixture)['executions'].values.select { |row| row['record_intent'] == phase_intent }
      with_individual_execution(fixture, phase_record, 'Organizator') do |e|
        assert_equal('tie_requires_resolution', e.progress['knockout_state'])
        pairings = e.knockout_preview
        assert_equal(:confirmed, pairings[:state])
        assert_equal(1, pairings[:plan]['round'])
        assert_equal([tied_players], pairings[:plan]['matches'].map { |match| match['participants'] })
        assert_equal([carried_winner], pairings[:plan]['replay']['resolved_results'].flat_map { |result| result['winners'] })
        assert_equal(:confirmed, e.knockout_accept(preview: pairings[:preview])[:state])
        shown = e.knockout_execution_preview
        assert_equal(:confirmed, shown[:state])
        accepted_replay = e.knockout_execution_accept(preview: shown[:preview])
        assert_equal(:confirmed, accepted_replay[:state])
        phase_record = accepted_replay[:record]
      end
      phase_intent = phase_record['preview']['intent_id']
      with_dispatch(fixture, phase_record, 'Organizator') { |d| d.configure(intent_id: phase_intent, max_tables: 2) }
      tied_players.each { |actor| with_dispatch(fixture, phase_record, actor) { |d| d.available(intent_id: phase_intent, available: true) } }
      2.times { tied_players.each { |actor| with_dispatch(fixture, phase_record, actor) { |d| d.advance(intent_id: phase_intent) } } }
      tied_players.each { |actor| with_dispatch(fixture, phase_record, actor) { |d| assert_equal(:confirmed, d.accept(intent_id: phase_intent)[:state]) } }
      tied_players.each { |actor| with_dispatch(fixture, phase_record, actor) { |d| d.advance(intent_id: phase_intent) } }
      additional = dispatch_state(fixture)['executions'].values.select { |row| row['record_intent'] == phase_intent && row['start'] }
      assert_equal(1, additional.size)
      assert_equal(tied_players.sort, dispatch_state(fixture)['busy'].keys.sort)
      replay_winner = additional.first['request']['players'].min_by { |person| person['seat'] }['account']
      finish_dispatch_board(fixture, phase_record, additional.first)
      with_individual_execution(fixture, phase_record, 'Organizator') do |e|
        assert_equal([carried_winner, replay_winner].sort, e.progress['qualified'].sort)
      end
      assert_equal(original_state, dispatch_state(fixture)['executions'].values.select { |row| row['record_intent'] == original_phase['preview']['intent_id'] })
      assert_equal(original_phase, fixture.backend(context: nil).readback(intent_id: original_phase['preview']['intent_id']))
      puts 'PASS mixed semifinal: only tied participants replay, other winner retained, original results unchanged'
    else
      boards.each { |row| finish_dispatch_board(fixture, phase_record, row) }
    end
    assert_equal({}, dispatch_state(fixture)['busy'])
    with_individual_execution(fixture, phase_record, 'Organizator') do |e|
      assert_equal('ready_next_round', e.progress['knockout_state'])
      assert_equal(2, e.progress['qualified'].size)
      assert_equal(nil, e.progress['champion'])
    end
    if ARGV.include?('--final')
      final_record = nil
      Timeout.timeout(60) do
      with_individual_execution(fixture, phase_record, 'Organizator') do |e, authority|
        pairings = e.knockout_preview
        assert_equal(:confirmed, pairings[:state])
        assert_equal(2, pairings[:plan]['round'])
        assert_equal(:confirmed, e.knockout_accept(preview: pairings[:preview])[:state])
        final_backend = fixture.backend(context: authority)
        final_record = final_backend.accept(preview: final_backend.knockout_execution_preview(parent_intent: phase_intent))
      end
      end
      final_intent = final_record['preview']['intent_id']
      finalists = final_record['evidence']['source']['roster'].map { |p| p['username'] }
      assert_equal(2, finalists.size)
      with_dispatch(fixture, final_record, 'Organizator') { |d| d.configure(intent_id: final_intent, max_tables: 2) }
      finalists.each { |actor| with_dispatch(fixture, final_record, actor) { |d| d.available(intent_id: final_intent, available: true) } }
      2.times { finalists.each { |actor| with_dispatch(fixture, final_record, actor) { |d| d.advance(intent_id: final_intent) } } }
      finalists.each { |actor| with_dispatch(fixture, final_record, actor) { |d| assert_equal(:confirmed, d.accept(intent_id: final_intent)[:state]) } }
      finalists.each { |actor| with_dispatch(fixture, final_record, actor) { |d| d.advance(intent_id: final_intent) } }
      final = dispatch_state(fixture)['executions'].values.find { |row| row['record_intent'] == final_intent && row['start'] }
      assert(final, 'Final must be a real started game')
      finish_dispatch_board(fixture, final_record, final)
      with_individual_execution(fixture, final_record, finalists.first) do |e|
        assert_equal('completed', e.progress['knockout_state'])
        assert_equal(1, e.progress['qualified'].size)
        assert_equal(e.progress['qualified'].first, e.progress['champion'])
        assert_equal(:tournament_completed, e.knockout_preview[:reason])
      end
      assert_equal({}, dispatch_state(fixture)['busy'])
      assert_equal(final_record, fixture.backend(context: nil).readback(intent_id: final_intent))
      assert_equal(phase_record, fixture.backend(context: nil).readback(intent_id: phase_intent))
    end
    assert_equal(record, fixture.backend(context: nil).readback(intent_id: intent))
  end
  phase_path = File.join(fixture.directory, 'k02', 'individual-v1', 'execution-v1', 'knockout-plans-v1', 'sandbox-k02.json')
  bytes = File.binread(phase_path)
  corrupted = JSON.parse(bytes)
  corrupted['records'].first['approval']['actor'] = 'beta'
  File.binwrite(phase_path, JSON.generate(corrupted))
  with_individual_execution(fixture, record, 'Organizator') do |e|
    assert_raises(T::Publication::Invalid) { e.knockout_readback }
  end
  File.binwrite(phase_path, bytes)
end
puts 'PASS knockout acceptance: actual Runner receipts, organizer authority, stale preview refusal, idempotent durable approval and unchanged group history'
