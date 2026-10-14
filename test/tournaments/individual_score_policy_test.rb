require_relative '../support/tournament_dispatch'
require_relative '../support/tournament_scored_game'
include TournamentDispatchSupport
lower = ARGV.include?('--lower')
registry = TournamentScoredGameSupport.registry(lower: lower)
(lower ? [T::GameResult::CURRENT_RESULT_POLICY] : [nil, *T::GameResult::EXPORT_POLICIES]).each do |policy|
  with_fixture(game: 'future_scored_game', registry: registry, names: %w[Alpha Beta], rematch: false) do |fixture|
    backend = fixture.backend
    shown = backend.preview(publication_ref: fixture.reference, base_seats: fixture.base,
      intent_id: 'score-policy', result_policy: policy)
    record = backend.accept(preview: shown)
    intent = record['preview']['intent_id']
    assert_equal(policy, record['evidence']['source']['result_policy'])
    fixture.now = record['evidence']['plan']['matches'].first['windows'].first['opens'] + 1
    with_dispatch(fixture, record, 'Organizator') { |d| d.configure(intent_id: intent, max_tables: 1) }
    %w[Alpha Beta].each { |actor| with_dispatch(fixture, record, actor) { |d| d.available(intent_id: intent, available: true) } }
    2.times { %w[Alpha Beta].each { |actor| with_dispatch(fixture, record, actor) { |d| d.advance(intent_id: intent) } } }
    %w[Alpha Beta].each { |actor| with_dispatch(fixture, record, actor) { |d| assert_equal(:confirmed, d.accept(intent_id: intent)[:state]) } }
    %w[Alpha Beta].each { |actor| with_dispatch(fixture, record, actor) { |d| d.advance(intent_id: intent) } }
    row = dispatch_state(fixture)['executions'].values.find { |value| value['start'] }
    finish_dispatch_board(fixture, record, row)
    result = dispatch_state(fixture)['executions'].values.first['result']['summary']
    assert_equal(lower ? [1, 9] : (policy ? [3, 10] : nil), result['scores']&.values&.sort)
    assert_equal(policy == T::GameResult::CURRENT_RESULT_POLICY ? (lower ? 'lower' : 'higher') : nil, result['score_order'])
    with_individual_execution(fixture, record, 'Alpha') do |execution|
      table = execution.progress['standings']
      assert_equal([2, 0], table.map { |unit| unit['points'] })
      assert_equal(lower ? [1, 9] : (policy ? [10, 3] : [nil, nil]), table.map { |unit| unit['score_for'] })
    end
    assert_equal(record, fixture.backend(context: nil).readback(intent_id: intent))
    assert_equal({}, dispatch_state(fixture)['busy'])
    if policy
      path = File.join(fixture.directory, 'k02/individual-v1/execution-v1/state.json')
      bytes = File.binread(path)
      damaged = JSON.parse(bytes)
      damaged['executions'].values.first['result']['summary']['scores'] = nil
      begin
        File.binwrite(path, JSON.generate(damaged))
        assert_raises(T::Publication::Invalid) do
          with_individual_execution(fixture, record, 'Alpha') { |execution| execution.progress }
        end
      ensure
        File.binwrite(path, bytes)
      end
      assert_equal(bytes, File.binread(path))
      if policy == T::GameResult::CURRENT_RESULT_POLICY
        damaged = JSON.parse(bytes)
        damaged['executions'].values.first['result']['summary']['score_order'] = lower ? 'higher' : 'lower'
        begin
          File.binwrite(path, JSON.generate(damaged))
          assert_raises(T::Publication::Invalid) do
            with_individual_execution(fixture, record, 'Alpha') { |execution| execution.progress }
          end
        ensure
          File.binwrite(path, bytes)
        end
        assert_equal(bytes, File.binread(path))
      end
    end
  end
end
puts 'PASS declared score export: future game works without an ID allowlist, durable new small scores, unchanged legacy scoring and cold plans'
