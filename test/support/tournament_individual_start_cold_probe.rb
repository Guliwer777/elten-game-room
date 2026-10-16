require_relative 'tournament_individual_execution'
include TournamentIndividualExecutionSupport
registry = ARGV.fetch(1) == 'future_individual' ? future_individual_registry : GameRoomGames::CATALOG
fixture = TournamentLocalExecutionPlanSupport::Fixture.new(ARGV.fetch(0), game: ARGV.fetch(1), reopen: true, registry: registry)
begin
  record = fixture.backend(context: nil).readback(intent_id: 'individual-start')
  with_individual_execution(fixture, record, 'Beta') do |execution|
    result = execution.local_game(action: :local_game_status)
    assert_equal(:confirmed, result[:state], result.inspect)
    assert_equal('start', result[:status]['receipt']['kind'])
    assert_equal((ARGV[2] || '0').to_i, result[:status]['event_count'])
    if ARGV[2] == '5'
      assert_equal(['beta'], result[:status]['result']['summary']['winners'])
      assert_equal('finished', result[:status]['phase'])
    end
    if ARGV[2] == '9'
      assert_equal([], result[:status]['result']['summary']['winners'])
      assert_equal(true, result[:status]['result']['summary']['draw'])
    end
  end
  puts 'PASS cold individual Start'
ensure
  fixture.close
end
