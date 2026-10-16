require_relative 'tournament_individual_execution'
require_relative '../../lib/tournaments/local_tournament_dispatcher'
module TournamentDispatchSupport
  include TournamentIndividualExecutionSupport
  def with_dispatch(fixture, record, actor)
    with_individual_execution(fixture, record, actor) do |_execution, authority, session|
      options = {plan_backend: fixture.backend(context: authority), plan_directory: File.join(fixture.directory, 'k02'),
        source_identity: fixture.tables.backend_identity, context: authority, registry: fixture.registry,
        clock: -> { fixture.now }, policy_ref: 'individual-technical-test-v1', expires_at: nil}
      yield T::LocalTournamentDispatcher.new(**options), session
    end
  end
  def dispatch_state(fixture)
    path = File.join(fixture.directory, 'k02/individual-v1/execution-v1/state.json')
    JSON.parse(File.read(path))
  end
  def finish_dispatch_board(fixture, record, row, moves: [[0,0],[1,0],[0,1],[1,1],[0,2]], clock: nil, finalize: true)
    play_dispatch_board(fixture, record, row, moves: moves, clock: clock)
    return unless finalize
    with_individual_execution(fixture, record, row['coordinator'], clock: clock) do |execution|
      request = row['request']
      execution.select(intent_id: record['preview']['intent_id'], match_id: request['match_id'], leg: request['leg'], window_id: request['window']['id'])
      status = execution.local_game(action: :local_game_status)[:status]
      assert_equal('finished', status['phase'])
      assert_equal(:confirmed, execution.local_game(action: :finalize_local_game, revision: status['revision'])[:state])
    end
  end
  def play_dispatch_board(fixture, record, row, moves:, clock: nil)
    people = row['request']['players'].sort_by { |person| person['seat'] }.map { |person| person['username'] }
    moves.each_with_index do |(x,y), index|
      with_individual_execution(fixture, record, people[index % 2], clock: clock) do |execution|
        request = row['request']
        execution.select(intent_id: record['preview']['intent_id'], match_id: request['match_id'], leg: request['leg'], window_id: request['window']['id'])
        status = execution.local_game(action: :local_game_status)[:status]
        result = execution.local_game(action: :local_game_move, operation_id: "#{request['match_id']}-#{index}",
          revision: status['revision'], move_selection: {'kind' => 'grid', 'action' => 'select', 'x' => x, 'y' => y})
        assert_equal(:confirmed, result[:state], result.inspect)
      end
    end
  end
end
