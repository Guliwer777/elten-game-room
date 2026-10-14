require_relative 'local_game_result'
require_relative 'local_private_choices'
module GameRoomTournaments
  # Both individual and declared team matches use the same ordinary Runner,
  # typed selections and actor-owned private protocol. No second game loop.
  module LocalGameExecutionActions
    def private_choices
      raise Publication::Invalid, :missing_selection unless selection
      @port.transaction do |document|
        key = CoordinationContract.digest(selection[:request].to_h.values_at('scope', 'match_id', 'leg', 'execution_generation'))
        execution = document['executions'][key]
        raise CoordinationContract::Blocked, :start_required unless execution && execution['start']
        LocalPrivateChoices.new(directory: @storage.directory, context: @context,
          session_id: execution['start']['session_id'], scope_digest: selection[:request].digest)
      end
    end

    private
    def run_game_action(action:, binding_digest: nil, operation_id: nil, revision: nil, move_selection: nil, realtime_input: nil)
      raise Publication::Invalid, :missing_selection unless selection
      private_vault = nil
      if @registry.build(selection[:request].to_h['game_id']).tournament_private_protocol?
        begin
          private_vault = private_choices
        rescue CoordinationContract::Blocked => error
          raise unless error.code == :start_required
        end
      end
      port = LocalGameResult.new(port: @port, storage: @storage, request: selection[:request],
        context: @context, record_reader: method(:record!), clock: @clock, native: selection[:native], registry: @registry,
        private_choices: private_vault, realtime_input: realtime_input)
      effect = case action
      when :start_local_game then port.start(binding_digest: binding_digest)
      when :local_game_move then port.move(operation_id: operation_id, revision: revision, selection: move_selection)
      when :local_move_status then port.read_move(operation_id: operation_id)
      when :finalize_local_game then port.finalize(revision: revision)
      when :local_game_status then nil
      when :local_game_surface then port.surface
      when :local_realtime_view then port.realtime_view
      else raise ArgumentError, 'Unknown game action'
      end
      if action == :local_realtime_view
        effect = effect.merge(request: selection[:request], native: selection[:native], registry: @registry,
          change_identity: Publication::Data.freeze_tree(Publication::Data.copy(@storage.identity))).freeze
      end
      state = action == :local_move_status && !effect ? :unknown : :confirmed
      begin
        {state: state, effect: effect, status: port.status}.freeze
      rescue Exception => error
        raise unless effect
        {state: state, effect: effect, status: nil, refresh_error: error}.freeze
      end
    rescue LocalFixedTeamExecutionStorage::Unconfirmed => error
      {state: :uncertain, receipt: error.receipt}.freeze
    rescue CoordinationContract::Blocked, ReadinessContract::Blocked => error
      {state: :blocked, reason: error.code}.freeze
    end
  end
end
