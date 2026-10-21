require_relative 'tournament_generic_team_round'
include TournamentGenericTeamRoundSupport
fixture = TournamentLocalExecutionPlanSupport::Fixture.new(ARGV.fetch(0), game: 'taboo', reopen: true)
size = Integer(ARGV.fetch(1))
begin
  bytes = File.binread(generic_team_state_path(fixture))
  record = nil
  with_declared_team_backend(fixture, 'Organizator') { |backend| record = backend.readback(intent_id: 'large-team-final') }
  assert_equal(2, record['evidence']['source']['source_version'])
  assert_equal(size, record['evidence']['source']['membership']['team_size'])
  with_declared_team_execution(fixture, record, 'Organizator') do |execution|
    progress = execution.progress
    assert_equal('completed', progress['knockout_state'])
    assert_equal(progress['qualified'].first, progress['champion'])
    assert_equal([2, 0], progress['standings'].map { |unit| unit['points'] }.sort.reverse)
    assert(progress['standings'].all? { |unit| unit.values_at('score_for', 'score_against') == [nil, nil] },
      'Cold Taboo standings restored unsupported small points')
  end
  state = generic_team_state(fixture)
  assert_equal({}, state['busy'])
  assert_equal(size * 2, state['native']['cores'].first['capacity'])
  assert_equal(bytes, File.binread(generic_team_state_path(fixture)))
  puts "PASS cold #{size * 2}-player team final: sealed source v2, genuine winner, team score counted once, unchanged archive"
ensure
  fixture.close
end
