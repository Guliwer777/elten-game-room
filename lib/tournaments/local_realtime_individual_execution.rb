require_relative 'local_individual_execution'
require_relative 'realtime_point_input'
module GameRoomTournaments
  # Client-capable composition used by the individual connection. A declared
  # point hook is required; the base executor still rejects realtime clients.
  class LocalRealtimeIndividualExecution < LocalIndividualExecution
    def local_game(realtime_input: nil, **options)
      run_game_action(**options, realtime_input: realtime_input)
    end
    private
    def validate_game_execution!(request)
      game = @registry.build(request['game_id'])
      return super unless game.tournament_execution_kind == :realtime
      raise Invalid, :realtime_execution_required unless game.tournament_realtime_point_action.is_a?(String)
    end
  end
end
