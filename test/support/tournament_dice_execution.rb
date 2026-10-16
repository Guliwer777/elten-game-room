require_relative 'tournament_dispatch'
module TournamentDiceExecutionSupport
  include TournamentDispatchSupport
  def finish_dispatch_farkle(fixture, record, row)
    request = row['request']
    intent = record['preview']['intent_id']
    request['players'].sort_by { |person| person['seat'] }.each_with_index do |person, seat|
      with_individual_execution(fixture, record, person['username']) do |execution|
        execution.select(intent_id: intent, match_id: request['match_id'], leg: request['leg'], window_id: request['window']['id'])
        [{'action' => 'roll'}, {'action' => 'keep', 'indices' => '0,1,2,3,4,5'}, {'action' => 'bank'}].each_with_index do |choice, step|
          status = execution.local_game(action: :local_game_status)[:status]
          result = execution.local_game(action: :local_game_move, operation_id: "#{request['match_id']}-#{request['leg']}-#{seat}-#{step}",
            revision: status['revision'], move_selection: choice.merge('kind' => 'dice'))
          assert_equal(:confirmed, result[:state], result.inspect)
        end
      end
    end
    with_individual_execution(fixture, record, row['coordinator']) do |execution|
      execution.select(intent_id: intent, match_id: request['match_id'], leg: request['leg'], window_id: request['window']['id'])
      status = execution.local_game(action: :local_game_status)[:status]
      assert_equal('finished', status['phase'])
      result = execution.local_game(action: :finalize_local_game, revision: status['revision'])
      assert_equal(:confirmed, result[:state], result.inspect)
      assert_equal(true, result[:effect]['summary']['draw'])
      assert_equal([200, 200, 200], result[:effect]['summary']['scores'].values.sort)
      result
    end
  end
end
