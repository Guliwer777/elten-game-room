require_relative 'tournament_generic_team_round'
include TournamentGenericTeamRoundSupport
$generic_round_time = Time.at(Float(ARGV.fetch(1)))
Time.singleton_class.prepend(Module.new do
  def now; $generic_round_time || super; end
end)
fixture = TournamentLocalExecutionPlanSupport::Fixture.new(ARGV.fetch(0), game: 'taboo', reopen: true)
begin
  before = generic_team_state(fixture)
  row = before['executions'].values.first
  assert_equal(nil, row['result'])
  assert_equal(4, row['moves'].size)
  assert_equal(row['request']['players'].size, before['busy'].size)
  record = nil
  with_declared_team_backend(fixture, 'Organizator') { |backend| record = backend.readback(intent_id: 'large-team-final') }
  finish_generic_team_taboo(fixture, record, 0)
  after = generic_team_state(fixture)
  finished = after['executions'].values.first
  assert_equal(row['start'], finished['start'])
  assert_equal(row['target'], finished['target'])
  assert_equal(row['moves'], finished['moves'].take(row['moves'].size))
  assert_equal(before['native']['creates'], after['native']['creates'])
  assert(finished['result'], 'Cold continuation must produce the actual game result')
  assert_equal({}, after['busy'])
  puts 'PASS larger-team cold continuation: same Start/target, immutable earlier moves, no duplicate core, actual result and released busy slots'
ensure
  fixture.close
end
