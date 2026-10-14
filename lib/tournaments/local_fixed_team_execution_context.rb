# encoding: UTF-8
require_relative 'local_readiness_session'
require_relative 'coordination_contract'

module GameRoomTournaments
  # Most lokalnego aktora i jawnego producenta zdarzeń koordynatora; bez I/O.
  class LocalFixedTeamExecutionContext
    def initialize(authority:, request:, coordinator_events:)
      unless authority.instance_of?(LocalReadinessSession::Context) && request.instance_of?(CoordinationRequest) &&
          coordinator_events.instance_of?(LocalReadinessSession::Events)
        raise Publication::Invalid, :invalid_composition
      end
      @authority, @request, @events = authority, request, coordinator_events
      @expected = ReadinessContract.frozen_copy(authority.call)
      @coordinator = coordinator_events.snapshot
      raise Publication::Invalid, :context_unavailable unless @coordinator[:epoch].positive? && @coordinator[:value]
    end

    def call
      current = @authority.call
      event = @events.snapshot
      {'account' => current['account'], 'backend_identity' => current['backend_identity'],
        'runtime' => current['runtime_id'], 'generation' => @request.to_h['execution_generation'],
        'epoch' => current['auth_epoch'], 'grant_epoch' => Integer(event[:value], 10),
        'cancelled' => current['cancelled'] || !current.eql?(@expected) || !event.eql?(@coordinator)}
    end
  end
end
