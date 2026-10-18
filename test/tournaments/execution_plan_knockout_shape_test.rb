require_relative '../support/tournament_declared_team_execution'
include TournamentDeclaredTeamExecutionSupport

cases = []
check_record = lambda do |record, registry|
  evidence = record.fetch('evidence')
  match = evidence.fetch('plan').fetch('matches').first
  selectors = {expected_source: record.fetch('expected_source'), match_id: match.fetch('match_id'),
    leg: match.fetch('leg'), window_id: match.fetch('windows').first.fetch('id'), registry: registry}
  build = ->(value) { T::CoordinationRequest.from_execution_plan(evidence: value, **selectors) }
  original = T::ExecutionPlanContract.copy(evidence)
  request = build.call(evidence).to_h
  assert_equal('direct_final', evidence.dig('source', 'knockout', 'origin'))
  assert_equal(2, evidence.dig('source', 'knockout', 'series', 'target'))

  {'seeds' => [[nil, true, false, 0, 0.0, '12', {}], :invalid_participants],
    'series' => [[nil, true, false, 0, 0.0, 'series', []], :invalid_fields]}.each do |field, (values, code)|
    values.each do |value|
      changed = T::ExecutionPlanContract.copy(evidence)
      changed.fetch('source').fetch('knockout')[field] = value
      before = T::ExecutionPlanContract.copy(changed)
      outcome = begin
        build.call(changed)
        {error: 'accepted', code: nil}
      rescue StandardError => error
        {error: error.class.name, code: error.respond_to?(:code) ? error.code : nil}
      end
      cases << {version: evidence.fetch('version'), field: field, value: value,
        expected: {error: 'GameRoomTournaments::Publication::Invalid', code: code}, outcome: outcome}
      assert_equal(before, changed, 'Malformed knockout data must not be changed in place')
    end
  end
  assert_equal(original, evidence)
  assert_equal(request, build.call(evidence).to_h, 'Valid knockout requests remain unchanged after refused inputs')
end

with_fixture(game: 'tic_tac_toe', names: %w[Alpha Beta], rematch: false,
    group_advancement: T::GroupAdvancement::COMPACT, final_wins_to: 2,
    knockout_rematch: false, final_rematch: false) do |fixture|
  backend = fixture.backend
  record = backend.accept(preview: backend.preview(publication_ref: fixture.reference,
    base_seats: fixture.base, intent_id: 'knockout-source-v1'))
  assert_equal(1, record.fetch('evidence').fetch('version'))
  check_record.call(record, fixture.registry)
  assert_equal(record, backend.readback(intent_id: 'knockout-source-v1'))
end
with_fixture(game: 'taboo', names: %w[Alpha Beta Gamma Delta Epsilon Zeta],
    players_per_match: 6, rematch: false, group_advancement: T::GroupAdvancement::COMPACT,
    final_wins_to: 2, knockout_rematch: false, final_rematch: false) do |fixture|
  with_declared_team_backend(fixture, 'Organizator') do |backend|
    record = backend.accept(preview: backend.preview_teams(publication_ref: fixture.reference,
      teams: [%w[alpha beta gamma], %w[delta epsilon zeta]],
      team_template: [0, 1, 0, 1, 0, 1], intent_id: 'knockout-source-v2'))
    assert_equal(2, record.fetch('evidence').fetch('version'))
    assert_equal(2, record.fetch('evidence').fetch('source').fetch('source_version'))
    check_record.call(record, fixture.registry)
    assert_equal(record, backend.readback(intent_id: 'knockout-source-v2'))
  end
end
failures = cases.reject { |row| row[:outcome] == row[:expected] }
assert_equal([], failures, 'Nested knockout shapes require typed validation before size or dig')
[nil, true, false, 0, 0.0, '', []].each do |metadata|
  error = assert_raises(T::Publication::Invalid) { T::KnockoutSchedule.matches(metadata: metadata, generation: 'unused') }
  assert_equal(:invalid_fields, error.code)
end
puts "PASS knockout source shapes: #{cases.size} v1/v2 refusals, seven direct metadata refusals, accepted first-to-two finals and readback unchanged"
