require_relative 'local_fixed_team_entry'
module GameRoomTournaments
  class LocalIndividualEntry < LocalFixedTeamEntry
    private
    def create_connection(lease)
      @workspace.individual_connection(context: @context, lease: lease, session: @session)
    end
  end
end
