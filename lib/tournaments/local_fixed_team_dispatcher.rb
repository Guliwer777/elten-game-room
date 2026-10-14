require_relative 'local_tournament_dispatcher'
require_relative 'local_fixed_team_native_provider'
module GameRoomTournaments
  # Family authority and native payload differ; queue, limits and invitations
  # use the same dispatcher and the game-declared accepted plan.
  class LocalFixedTeamDispatcher < LocalTournamentDispatcher
    private
    def storage_class; LocalFixedTeamExecutionStorage; end
    def execution_class; LocalFixedTeamExecution; end
    def native_provider(match); LocalFixedTeamNativeProvider.new(capacity: match['players'].size); end
  end
end
