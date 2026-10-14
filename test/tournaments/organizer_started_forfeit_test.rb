require_relative '../support/tournament_dispatch'
include TournamentDispatchSupport
[:unfinished, :finished, :lost_ack].each do |scenario|
  with_fixture(game: 'tic_tac_toe', names: %w[Alpha Beta], rematch: false) do |fixture|
    record = start_individual_match(fixture, intent_id: "forfeit-#{scenario}")
    row = dispatch_state(fixture)['executions'].values.first
    if scenario == :finished
      play_dispatch_board(fixture, record, row, moves: [[0,0],[1,0],[0,1],[1,1],[0,2]])
    else
      play_dispatch_board(fixture, record, row, moves: [[0,0]])
    end
    with_individual_execution(fixture, record, 'Organizator') do |execution|
      before = execution.organizer_result_status
      if scenario == :lost_ack
        storage = execution.instance_variable_get(:@storage)
        original = storage.method(:write)
        storage.define_singleton_method(:write) do |document, receipt: nil|
          original.call(document, receipt: receipt)
          raise T::LocalFixedTeamExecutionStorage::Unconfirmed.new(attempt_id: 'lost-ack', receipt: receipt)
        end
      end
      result = execution.organizer_forfeit(operation_id: "decision-#{scenario}", winner: 'beta', reason: 'Organizer decision', expected_revision: before[:revision])
      if scenario == :finished
        assert_equal(:game_already_finished, result[:reason])
        assert_equal(nil, execution.organizer_result_status[:result])
      else
        assert_equal(scenario == :lost_ack ? :uncertain : :confirmed, result[:state], result.inspect)
        assert_equal('forfeit', execution.organizer_result_status[:result]['kind'])
        assert_equal({}, dispatch_state(fixture)['busy'])
        assert(dispatch_state(fixture)['native']['cores'].all? { |core| core['closed'] }, 'Native room still open')
      end
    end
    with_individual_execution(fixture, record, 'Organizator') do |execution|
      assert_equal(scenario != :finished, execution.progress['complete'])
    end
  end
end
puts 'PASS started organizer forfeit: preserve moves, release busy room, reject completed game, reconcile lost acknowledgement'
