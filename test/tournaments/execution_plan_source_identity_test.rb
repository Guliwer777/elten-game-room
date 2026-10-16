require_relative '../support/tournament_execution_plan'
require_relative '../support/assertions'
include GameRoomTest::Assertions
E = TournamentExecutionPlanFixture
T = GameRoomTournaments

[257, 4096].each do |size|
  evidence = E.evidence
  evidence['source']['backend_identity'] = 'x' * size
  evidence['seal']['source_digest'] = evidence['plan']['source_digest'] = E.digest(evidence['source'])
  evidence['plan_digest'] = E.digest(evidence.slice('scope', 'plan'))
  assert_equal(E.expected(evidence), E.request(evidence).to_h)
end
evidence = E.evidence
evidence['source']['backend_identity'] = 'x' * 4097
assert_raises(T::Publication::Invalid) { T::ExecutionPlanContract.source!(evidence['source']) }
puts 'PASS execution source identities: long local paths through the complete request, bounded at 4096 bytes'
