# encoding: UTF-8
require_relative '../support/tournament_execution_plan'
require_relative '../support/tournament_declared_team_execution'
include TournamentDeclaredTeamExecutionSupport

cases = []
check_shapes = lambda do |evidence, anchor, registry|
  match = evidence.fetch('plan').fetch('matches').first
  selectors = {expected_source: anchor, match_id: match.fetch('match_id'),
    leg: match.fetch('leg'), window_id: match.fetch('windows').first.fetch('id'), registry: registry}
  build = ->(value) { T::CoordinationRequest.from_execution_plan(evidence: value, **selectors) }
  original = T::ExecutionPlanContract.copy(evidence)
  expected = build.call(evidence).to_h
  assert_equal(original, evidence, 'Valid request construction must not modify its evidence')

  %w[source knockout].each do |field|
    [nil, true, false, 0, 0.0, '', [], {}].each do |value|
      changed = T::ExecutionPlanContract.copy(evidence)
      target = field == 'source' ? changed : changed.fetch('source')
      target[field] = value
      before = T::ExecutionPlanContract.copy(changed)
      outcome = begin
        build.call(changed)
        {error: 'accepted', code: nil}
      rescue StandardError => error
        {error: error.class.name, code: error.respond_to?(:code) ? error.code : nil}
      end
      cases << {version: evidence.fetch('version'), field: field, value: value, outcome: outcome}
      assert_equal(before, changed, 'Rejected evidence must not be normalized or repaired in place')
    end
  end
  assert_equal(expected, build.call(evidence).to_h, 'Malformed inputs must not poison the valid request')
end

individual = TournamentExecutionPlanFixture.evidence
check_shapes.call(individual, TournamentExecutionPlanFixture.anchor(individual), GameRoomGames::CATALOG)

# Produce a valid v2 plan through the existing backend, including the larger-team
# source v2 membership and policy. Merely changing a v1 version number would not
# reach the malformed optional knockout boundary behind source validation.
with_fixture(game: 'taboo', names: %w[Alpha Beta Gamma Delta Epsilon Zeta],
    players_per_match: 6, rematch: false) do |fixture|
  with_declared_team_backend(fixture, 'Organizator') do |backend|
    preview = backend.preview_teams(publication_ref: fixture.reference,
      teams: [%w[alpha beta gamma], %w[delta epsilon zeta]],
      team_template: [0, 1, 0, 1, 0, 1], intent_id: 'source-shape-contract')
    record = backend.accept(preview: preview)
    assert_equal(2, record.fetch('evidence').fetch('version'))
    assert_equal(2, record.fetch('evidence').fetch('source').fetch('source_version'))
    check_shapes.call(record.fetch('evidence'), record.fetch('expected_source'), fixture.registry)
    assert_equal(record, backend.readback(intent_id: 'source-shape-contract'))
  end
end

failures = cases.reject do |row|
  row[:outcome] == {error: 'GameRoomTournaments::Publication::Invalid', code: :invalid_fields}
end
assert_equal([], failures, 'Malformed plan sources require typed validation refusals, not runtime exceptions')
puts "PASS plan source shapes: #{cases.size} controlled refusals, valid v1/v2 requests unchanged, real larger-team plan readback"
