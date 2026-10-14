require_relative 'tournament_generic_team_round'
include TournamentGenericTeamRoundSupport
fixture = TournamentLocalExecutionPlanSupport::Fixture.new(ARGV.fetch(0), game: ARGV.fetch(1, 'domino'), reopen: true)
size = Integer(ARGV.fetch(2, '2'))
begin
  bytes = File.binread(generic_team_state_path(fixture))
  state = generic_team_state(fixture)
  assert_equal({}, state['busy'])
  assert_equal(2, state['native']['creates'].size)
  assert_equal(2, state['executions'].values.count { |row| row['result'] && row['moves'].size > 10 })
  records = nil
  with_declared_team_backend(fixture, 'Organizator') { |backend| records = backend.accepted_records }
  assert_equal(2, records.size)
  records.each do |record|
    assert([T::GameResult::DRAW_RESULT_POLICY, T::GameResult::CURRENT_RESULT_POLICY].include?(record['evidence']['source']['result_policy']))
    assert_equal(size, T::FixedTeamSeats.unit_size(record['evidence']['source']['membership']))
    assert_equal(size == 2 ? 1 : 2, record['evidence']['source']['source_version'])
    with_declared_team_execution(fixture, record, 'Organizator') do |execution|
      progress = execution.progress
      if record['preview']['intent_id'] == 'generic-teams'
        assert_equal('tie_requires_resolution', progress['knockout_state'])
        assert_equal([1, 1], progress['standings'].map { |unit| unit['points'] })
      else
        assert_equal('completed', progress['knockout_state'])
        assert_equal(progress['qualified'].first, progress['champion'])
      end
    end
  end
  assert_equal(bytes, File.binread(generic_team_state_path(fixture)))
  puts 'PASS cold generic team replay: original genuine draw, accepted additional game, actual champion and unchanged bytes'
ensure
  fixture.close
end
