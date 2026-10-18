require_relative '../support/tournament_individual_execution'
include TournamentIndividualExecutionSupport

checks = 0
with_fixture(game: 'tic_tac_toe', names: %w[Alpha Beta Gamma Delta], rematch: false,
    group_advancement: T::GroupAdvancement::AUTOMATIC) do |fixture|
  backend = fixture.backend
  record = backend.accept(preview: backend.preview(publication_ref: fixture.reference,
    base_seats: fixture.base, intent_id: 'phase-wrapper-parent'))
  # This tests the local approval adapter only. These pure sporting summaries
  # are not authenticated game receipts and are never published to a server.
  receipts = record['evidence']['plan']['matches'].map do |match|
    people = match['players'].map { |person| person['account'] }.sort
    {'record_intent' => record['preview']['intent_id'], 'match_id' => match['match_id'], 'leg' => match['leg'],
      'summary' => {'participants' => people, 'winners' => [people.first], 'draw' => false, 'scores' => nil, 'score_order' => 'higher'}}
  end
  phase = T::KnockoutPhase.build(record: record, receipts: receipts)
  backend.send(:phase_approval_store).accept(preview: phase, current: phase)
  shown = backend.knockout_execution_preview(parent_intent: record['preview']['intent_id'])
  accepted = backend.accept(preview: shown)
  assert_equal(accepted, backend.accept(preview: shown))
  assert_equal(accepted, backend.readback(intent_id: shown['intent_id']))
  path = backend.instance_variable_get(:@phase_storage).path
  original = File.binread(path)
  values = [nil, true, false, 0, 0.0, 'bad', [], {}]
  paths = [%w[source knockout_approval preview], %w[source knockout_approval preview plan],
    %w[source knockout_approval preview parent], %w[source knockout_approval preview receipts]]
  paths.each do |keys|
    values.each do |value|
      input = JSON.parse(JSON.generate(shown))
      parent = keys[0...-1].inject(input) { |node, key| node.fetch(key) }
      parent[keys.last] = value
      before = JSON.generate(input)
      assert_raises(T::Publication::Invalid) { backend.accept(preview: input) }
      assert_equal(before, JSON.generate(input))
      assert_equal(original, File.binread(path), 'Malformed phase approval modified the accepted execution')
      checks += 1
    end
  end
  values.each do |value|
    [value, {'preview' => value}].each do |malformed|
      changed = JSON.parse(original)
      changed['records'] << malformed
      bytes = JSON.generate(changed)
      begin
        File.binwrite(path, bytes)
        assert_raises(T::Publication::Invalid) { backend.readback(intent_id: shown['intent_id']) }
        assert_equal(bytes.b, File.binread(path), 'Cold phase read modified malformed data')
      ensure
        File.binwrite(path, original)
      end
      checks += 1
    end
  end
  assert_equal(accepted, backend.readback(intent_id: shown['intent_id']))
  assert_equal(record, backend.readback(intent_id: record['preview']['intent_id']))
  assert_equal(original, File.binread(path))
end
puts "PASS local knockout execution shapes: #{checks} typed refusals, parent/phase readback and immutable approvals retained"
