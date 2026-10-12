# frozen_string_literal: true

require_relative '../../games/axel_pong'
require_relative '../../games/audio_ball'
require_relative '../../games/duck_racing_support/challenges'

module GameRoomDuckRacing
  # This is a local view of two race seats, not a second session or game log.
  # The race remains the only authority for accepting and scoring the point.
  class RealtimeProjection
    KINDS = %w[axel_pong audio_ball].freeze
    attr_reader :id, :kind, :participants, :players, :seed, :first_server, :game, :replay

    def self.from(parent_replay, owner:)
      return unless parent_replay && !parent_replay.finished?
      challenge = parent_replay.state&.dig(:race, :challenge)
      return unless challenge.is_a?(Hash) && KINDS.include?(challenge[:kind])
      new(challenge, parent_replay.players, owner: owner)
    end

    def initialize(challenge, racers, owner:)
      @id, @kind, @seed = challenge.values_at(:id, :kind, :seed)
      seats = challenge[:participants]
      valid = @id.is_a?(Integer) && @id.positive? && KINDS.include?(@kind) &&
        @seed.is_a?(Integer) && @seed >= 0 && racers.is_a?(Array) &&
        seats.is_a?(Array) && seats.length == 2 && seats.uniq.length == 2 &&
        seats.all? { |seat| seat.is_a?(Integer) && seat.between?(0, racers.length - 1) }
      raise ArgumentError, 'Invalid realtime race challenge' unless valid
      pair = seats.map { |seat| racers.fetch(seat) }
      unless pair.all? { |name| name.is_a?(String) && !name.empty? } && pair.map(&:downcase).uniq.length == 2
        raise ArgumentError, 'Invalid realtime race participants'
      end

      @kind = @kind.dup.freeze
      @participants = seats.dup.freeze
      @players = pair.map { |name| name.dup.freeze }.freeze
      @first_server = Random.new(@seed).rand(2)
      @game = @kind == 'axel_pong' ? GameRoomGames::AxelPong.new : GameRoomGames::AudioBall.new
      options = @game.default_options.merge('difficulty' => @kind == 'axel_pong' ? 2 : 3)
      state = {options: options, owner: owner.to_s.dup, scores: [0, 0], rally: 0}
      if @kind == 'audio_ball'
        state.merge!(sets: [0, 0], set_number: 1, first_server: @first_server,
          server: @first_server, last_point: nil, set_resume_at: nil)
      end
      @replay = GameRoomGames::Replay.new(board: nil, players: @players.dup,
        current_player: nil, winner: nil, draw: false, accepted_events: [], history: [], state: state)
    end

    def identity
      [@id, @kind, @participants, @players, @seed]
    end

    def matches?(parent_replay)
      return false unless parent_replay && !parent_replay.finished?
      challenge = parent_replay.state&.dig(:race, :challenge)
      challenge.is_a?(Hash) && challenge.values_at(:id, :kind, :seed) == [@id, @kind, @seed] &&
        challenge[:participants] == @participants &&
        @participants.map { |seat| parent_replay.players[seat] } == @players
    end

    def match_scope
      "duck:#{@id}"
    end

    def surface_spec(viewer)
      @game.surface_spec(@replay, viewer)
    end

    def shortcuts(viewer)
      @game.custom_game_shortcuts(@replay, viewer)
    end
  end
end
