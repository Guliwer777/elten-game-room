require_relative 'local_fixed_team_execution_storage'
require_relative 'local_execution_plan_backend'
require_relative 'individual_bound_target'
require_relative 'individual_native_target_adapter'
require_relative 'local_game_moves'
require_relative 'local_game_result'
require_relative 'local_private_choices'
module GameRoomTournaments
  class LocalIndividualExecutionStorage < LocalFixedTeamExecutionStorage
    def plan_backend_class; LocalExecutionPlanBackend; end
    def execution_namespace; ['individual-v1', 'execution-v1']; end
    def bound_target_class; IndividualBoundTarget; end
    def native_payload_class; IndividualNativePayload; end
    def native_adapter_class; IndividualNativeTargetAdapter; end
    def moves_class; LocalGameMoves; end
    def result_class; LocalGameResult; end
  end
end
