require_relative 'local_fixed_team_execution'
require_relative 'local_individual_execution_storage'
require_relative 'local_private_choices'
module GameRoomTournaments
  class LocalIndividualProgress < LocalFixedTeamProgress
    def self.standings_class; LocalIndividualStandings; end
  end
  # Explicit individual v1 authority; rules and results belong to the game.
  class LocalIndividualExecution < LocalFixedTeamExecution
    def local_game(action:, binding_digest: nil, operation_id: nil, revision: nil, move_selection: nil)
      run_game_action(action: action, binding_digest: binding_digest, operation_id: operation_id,
        revision: revision, move_selection: move_selection)
    end
    private
    def knockout_unit_count; selection[:request].to_h['players'].size; end
    def storage_class; LocalIndividualExecutionStorage; end
    def progress_class; LocalIndividualProgress; end
    def validate_game_execution!(request)
      capability = @registry.tournament_capabilities(request['game_id'], options: request['options'])
      raise Invalid, :realtime_execution_required unless capability[:execution] == :turn_based
    end
  end
end
