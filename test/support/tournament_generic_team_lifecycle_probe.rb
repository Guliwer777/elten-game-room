require_relative 'tournament_generic_team_round'
include TournamentGenericTeamRoundSupport
fixture = TournamentLocalExecutionPlanSupport::Fixture.new(ARGV.fetch(0), game: 'taboo', reopen: true)
size = Integer(ARGV.fetch(1, '2'))
begin
  path = generic_team_state_path(fixture)
  bytes = File.binread(path)
  state = generic_team_state(fixture)
  assert_equal({}, state['busy'])
  assert_equal(5, state['native']['creates'].size)
  assert_equal(5, state['executions'].values.count { |row| row['result'] && row['moves'].size >= 19 })
  records = nil
  with_declared_team_backend(fixture, 'Organizator') { |backend| records = backend.accepted_records }
  assert_equal(3, records.size)
  records.each do |record|
    assert([T::GameResult::DRAW_RESULT_POLICY, T::GameResult::CURRENT_RESULT_POLICY].include?(record['evidence']['source']['result_policy']))
    assert_equal(size, T::FixedTeamSeats.unit_size(record['evidence']['source']['membership']))
    assert_equal(size == 2 ? 1 : 2, record['evidence']['source']['source_version'])
    with_declared_team_execution(fixture, record, 'Organizator') do |execution|
      progress = execution.progress
      assert_equal(true, progress['complete'])
      candidate = record['preview']['source']['candidate']
      if candidate['format'] == 'groups_knockout'
        assert_equal('ready_knockout', progress['group_state'])
      elsif candidate['knockout']['round'] == 1
        assert_equal('ready_next_round', progress['knockout_state'])
      else
        assert_equal('completed', progress['knockout_state'])
        assert_equal(progress['qualified'].first, progress['champion'])
      end
    end
  end
  assert_equal(bytes, File.binread(path))
  puts 'PASS cold generic team lifecycle: five genuine games, three immutable v3 ancestors and the real champion'
ensure
  fixture.close
end
