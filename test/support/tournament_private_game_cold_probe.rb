require_relative 'tournament_individual_execution'
include TournamentIndividualExecutionSupport
fixture = TournamentLocalExecutionPlanSupport::Fixture.new(ARGV.fetch(0), game: 'battleship', reopen: true)
begin
  record = fixture.backend(context: nil).readback(intent_id: 'individual-start')
  with_individual_execution(fixture, record, 'Beta') do |execution|
    status = execution.local_game(action: :local_game_status)[:status]
    assert_equal(ARGV.fetch(1), status['phase'])
    assert_equal('private', status['last_move']['selection']['kind'])
    vault = execution.private_choices
    own = vault.reveal(session_id: status['session_id'], round_id: 'fleet', user: 'Beta')
    assert(own && vault.verify(own), 'Missing verified own fleet after cold start')
    assert_raises(T::ReadinessContract::Blocked) { vault.reveal(session_id: status['session_id'], round_id: 'fleet', user: 'Alpha') }
  end
  puts 'PASS cold private game'
ensure
  fixture.close
end
