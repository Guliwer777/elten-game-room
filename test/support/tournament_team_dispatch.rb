require_relative 'tournament_fixed_team_execution'
require_relative '../../lib/tournaments/local_fixed_team_dispatcher'

module TournamentTeamDispatchSupport
  include TournamentFixedTeamExecutionSupport

  def with_team_dispatch(context, actor)
    actor_backend(context, actor) do |backend, authority, directory|
      yield T::LocalFixedTeamDispatcher.new(plan_backend: backend, plan_directory: directory,
        source_identity: context.provider.backend_identity, context: authority, registry: REGISTRY,
        clock: -> { context.now }, policy_ref: 'team-knockout-lifecycle-test', expires_at: nil)
    end
  end

  def team_dispatch_state(context)
    JSON.parse(File.read(File.join(context.directory, 'plany/fixed-teams-v1/execution-ft2-v1/state.json')))
  end

  def with_team_match(context, record, actor, match_index = 0)
    execution_for(context, record, actor, native_provider: T::LocalFixedTeamNativeProvider.new) do |execution|
      match = record['evidence']['plan']['matches'].fetch(match_index)
      execution.select(intent_id: record['preview']['intent_id'], match_id: match['match_id'], leg: match['leg'], window_id: match['windows'].first['id'])
      yield execution
    end
  end

  def finish_team_dispatch_board(context, record, row, finalize: true)
    index = record['evidence']['plan']['matches'].index { |match| match['match_id'] == row['request']['match_id'] }
    coordinator = row['request']['players'].find { |person| person['account'] == row['coordinator'] }['username']
    view = nil
    (Array(row['moves']).size...60).each do |number|
      outcome = with_team_match(context, record, coordinator, index) { |execution| execution.local_game(action: :local_game_status) }
      assert_equal(:confirmed, outcome[:state], outcome.inspect)
      view = outcome.fetch(:status)
      break if view['finished']
      actor = view['current_player'] || view['players'].first
      with_team_match(context, record, actor, index) do |execution|
        own = execution.local_game(action: :local_game_status).fetch(:status)
        selection = own['actions'].find { |action| action['action'] == 'bid_3' } || own['actions'].first
        assert(selection, "No legal action for #{actor}")
        result = execution.local_game(action: :local_game_move, operation_id: "#{row['request']['match_id']}-team-move-#{number}",
          revision: own['revision'], move_selection: selection)
        assert_equal(:confirmed, result[:state])
      end
      puts "Recorded team round #{record['preview']['intent_id']} move #{number + 1}" if number % 20 == 0
    end
    assert_equal(true, view['finished'])
    return unless finalize
    with_team_match(context, record, coordinator, index) do |execution|
      assert_equal(:confirmed, execution.local_game(action: :finalize_local_game, revision: view['revision'])[:state])
    end
  end
end
