require_relative 'tournament_individual_execution'
include TournamentIndividualExecutionSupport
fixture = TournamentLocalExecutionPlanSupport::Fixture.new(ARGV.fetch(0), game: ARGV.fetch(1), reopen: true)
begin
  record = fixture.backend.readback(intent_id: ARGV.fetch(2))
  path = File.join(fixture.directory, 'k02/individual-v1/execution-v1/state.json')
  assert_equal(2, JSON.parse(File.binread(path))['busy'].size)
  commands = JSON.parse(ARGV.fetch(3))
  commands.each do |command|
    with_individual_execution(fixture, record, command.fetch('actor')) do |execution|
      status = execution.local_game(action: :local_game_status)[:status]
      assert_equal(command.fetch('before_count'), status['event_count'])
      result = execution.local_game(action: :local_game_move, operation_id: command.fetch('id'),
        revision: status['revision'], move_selection: command.fetch('selection'))
      assert_equal(:confirmed, result[:state], result.inspect)
    end
  end
  actor = commands.last.fetch('actor')
  with_individual_execution(fixture, record, actor) do |execution|
    status = execution.local_game(action: :local_game_status)[:status]
    assert_equal('finished', status['phase'])
    result = execution.local_game(action: :finalize_local_game, revision: status['revision'])
    assert_equal(:confirmed, result[:state], result.inspect)
    assert_equal(true, execution.progress['complete'])
  end
  puts 'PASS cold resume and finish through ordinary runner'
ensure
  fixture.close
end
