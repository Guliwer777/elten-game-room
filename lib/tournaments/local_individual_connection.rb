require_relative 'local_fixed_team_connection'
require_relative 'local_individual_execution'
require_relative 'local_tournament_dispatcher'
require_relative 'local_dispatch_runtime'
require_relative 'local_realtime_individual_execution'
module GameRoomTournaments
  class LocalIndividualConnection < LocalFixedTeamConnection
    POLICY = 'local-individual-technical-trial-v1'.freeze
    def plan_preview(**input); @backend.preview(**input); end
    private
    def dispatcher_class; LocalTournamentDispatcher; end
    def backend_class; LocalExecutionPlanBackend; end
    def execution_class; LocalRealtimeIndividualExecution; end
    def native_provider(request); IndividualNativeProvider.new(capacity: request['players'].size); end
  end
end
