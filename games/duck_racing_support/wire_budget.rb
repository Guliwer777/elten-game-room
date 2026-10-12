# frozen_string_literal: true

require_relative '../../lib/game_action_payload'
require_relative 'private_trace_stream'

module GameRoomDuckRacing
  # The legacy fragment count and the native stack-entry byte limit are
  # separate contracts. A whole fragmented ActionPlan occupies one native
  # packet; include its actual metadata and every Writer-generated UUID.
  module WireBudget
    UUID = '00000000-0000-0000-0000-000000000000'.freeze
    module_function

    def plan(game_id, data, replay:, actor:, limit:)
      unless limit.is_a?(Integer) && limit.positive?
        raise ArgumentError, 'The native stack-entry byte limit is unavailable'
      end
      wire = data
      if data['action'] == 'reveal' && data['page'].is_a?(Hash)
        wire = data.merge('page' => PrivateTraceStream.wire_page(data['page']))
      end
      events = GameRoomActionPayload.commands(game_id, wire)
      packet = GameRoomEventProtocol.game_action_packet(session_id: replay.state.fetch(:session_id),
        sequence: replay.accepted_events.to_a.map { |event| event['sequence'].to_i + 1 }.max.to_i,
        control_epoch: replay.state[:bot_controller_epoch], actor: actor,
        # false is one byte longer than true; this also safely budgets bot and
        # spectator-host actions without guessing their executor's authority.
        controller: false, events: events.map { |event| GameRoomEventProtocol.normalized(event).merge('move_id' => UUID) })
      bytes = JSON.generate(packet).bytesize
      raise ArgumentError, "The native action needs #{bytes} bytes; only #{limit} are available" if bytes > limit

      GameRoomGames::ActionPlan.new(events: events)
    end
  end
end
