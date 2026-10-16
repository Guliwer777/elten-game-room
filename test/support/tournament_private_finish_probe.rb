require_relative 'tournament_individual_execution'
include TournamentIndividualExecutionSupport
fixture = TournamentLocalExecutionPlanSupport::Fixture.new(ARGV.fetch(0), game: 'battleship', reopen: true)
begin
  record = fixture.backend(context: nil).readback(intent_id: 'individual-start')
  with_individual_execution(fixture, record, 'Beta') do |execution|
    status = execution.local_game(action: :local_game_status)[:status]
    assert_equal('finished', status['phase'])
    result = execution.local_game(action: :finalize_local_game, revision: status['revision'])
    assert_equal(:confirmed, result[:state], result.inspect)
    assert_equal(['beta'], result[:effect]['summary']['winners'])
    assert_equal(1, result[:status]['results'].size)
    assert_equal(result[:effect], execution.local_game(action: :finalize_local_game, revision: status['revision'])[:effect])
  end
  path = File.join(fixture.directory, 'k02', 'individual-v1', 'execution-v1', 'state.json')
  bytes = File.binread(path)
  output = IO.popen([RbConfig.ruby, File.expand_path('tournament_private_game_cold_probe.rb', __dir__), fixture.directory, 'finished'], err: [:child, :out], &:read)
  assert($?.success?, output)
  assert_equal(bytes, File.binread(path))
  puts 'PASS complete private Battleship result: actual winner, authorized coordinator, idempotent finalization and cold read-only archive'
ensure
  fixture.close
end
