require_relative 'tournament_individual_execution'
include TournamentIndividualExecutionSupport
fixture = TournamentLocalExecutionPlanSupport::Fixture.new(ARGV.fetch(0), game: 'tic_tac_toe', reopen: true)
begin
  record = fixture.backend(context: nil).readback(intent_id: 'individual-start')
  with_individual_execution(fixture, record, 'Alpha') do |execution|
    session_id = execution.local_game(action: :local_game_status)[:status]['session_id']
    vault = execution.private_choices
    envelope = vault.reveal(session_id: session_id, round_id: 'round-1', user: 'Alpha')
    assert_equal({'answer' => 'my-secret'}, envelope.payload)
    assert(vault.verify(envelope), 'Cold envelope failed verification')
  end
  puts 'PASS cold private choice'
ensure
  fixture.close
end
