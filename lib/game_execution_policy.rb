require_relative "game_participants"
require_relative "game_simulation"
require_relative "tournament_marker"

# Shared decisions, not a shared scheduler. Realtime clients retain their own
# loop; the turn runner retains its lease, locks and post-planning validation.
module GameRoomExecutionPolicy
  def self.departed_players(game:, replay:, session:, players:, members:, owner:, viewer:, transport:)
    return [] unless replay && members && GameRoomParticipants.same?(owner, viewer)
    return [] if GameRoomTournamentMarker.present?(session)
    return [] if replay.finished? || session["__frozen"] || session["__aborted"] || session["__control_ready"] == false
    return [] unless transport.respond_to?(:set_seat_controller)
    controllers = session.fetch("__controllers", {})
    players.reject do |seat|
      GameRoomParticipants.bot?(seat) || controllers[seat] == "bot" || GameRoomParticipants.includes?(members, seat) ||
        game.participant_replacement_error(replay, player: seat) != nil
    end
  end

  def self.bot_seed(repository, session, replay)
    repository.session_id(session).to_i * 1_000_003 +
      replay.accepted_events.map { |event| repository.event_id(event) }.max.to_i * 97 + replay.accepted_events.length
  end

  def self.bot_decision(game:, session:, replay:, repository:, coordinator:, context:, players:, controlled_actors: nil)
    simulation = nil
    simulation_factory = lambda do
      simulation ||= GameRoomSimulation::Environment.from_snapshot(game: game, session: session,
        events: replay.accepted_events, players: players, seed: bot_seed(repository, session, replay))
    end
    arguments = { game: game, replay: replay, context: context, simulation_factory: simulation_factory }
    arguments[:controlled_actors] = controlled_actors unless controlled_actors.nil?
    coordinator.decide_next(**arguments)
  end
end
