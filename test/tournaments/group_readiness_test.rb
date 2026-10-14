require_relative '../support/tournament_local_execution_plan'
require_relative '../../lib/tournaments/local_readiness_backend'
include TournamentLocalExecutionPlanSupport
with_fixture(game: 'chess', names: %w[Alpha Beta Charlie Delta], rematch: true,
  group_count: 2, places_per_group: 1) do |fixture|
  candidate = fixture.author_service.schedule_candidate(publication_ref: fixture.reference)
  source = ->(_reference) { candidate }
  backend = T::LocalReadinessBackend.new(directory: File.join(fixture.directory, 'group-readiness'),
    actor: 'Alpha', clock: -> { fixture.now }, source: source)
  record = backend.accept(candidate: candidate)
  assert_equal(2, record['candidate']['groups'].size)
  assert_equal(4, record['candidate']['matches'].size)
  own = record['candidate']['matches'].select { |match| match['players'].include?('alpha') }
  assert_equal(2, own.size)
  own.each { |match| assert(backend.target(plan_id: record['plan_id'], match_id: match['match_id']), 'group target exists') }
  assert_equal(record, backend.plans.first)
end
puts 'PASS group readiness: accepted complete candidate, own targets and return matches'
