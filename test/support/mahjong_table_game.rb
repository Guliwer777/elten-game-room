require_relative '../../games/mahjong_support/table_game'

module MahjongTableGameTest
  class Game < GameRoomGames::Base
    include GameRoomGames::MahjongTableGame
    def id; 'mahjong'; end
    def name; 'Mahjong'; end
    def minimum_players; 3; end
    def maximum_players; 4; end
    def option_definitions
      [GameRoomGames::OptionDefinition.new(key: 'variant', label: 'Variant', kind: :choice, default: 'mcr',
        choices: %w[mcr riichi hong_kong].map { |value| GameRoomGames::OptionChoice.new(value: value, label: value) }),
       GameRoomGames::OptionDefinition.new(key: 'seats', label: 'Seats', kind: :integer, default: 4),
       GameRoomGames::OptionDefinition.new(key: 'match_winds', label: 'Match winds', kind: :integer, default: 0)]
    end
  end

  class Repository
    def players_for(session); session.fetch('players'); end
    def actor_of(event, _session); event.fetch('actor'); end
    def event_id(event); event.fetch('id'); end
    def session_id(session); session.fetch('id'); end
  end

  class RandomSource
    Roll = Struct.new(:values, keyword_init: true)
    attr_reader :calls
    def initialize; @calls = 0; end
    def roll(count:, sides:)
      raise 'Unexpected mahjong deal random request' unless count == 8 && sides == 256
      @calls += 1
      Roll.new(values: [1, 2, 3, 4, 5, 6, 7, 8])
    end
  end

  def table_event(number, command, actor:)
    {'id'=>number, 'action'=>command.action, 'value'=>command.value, 'actor'=>actor}
  end

  def round_snapshot(round)
    return nil unless round
    flow = round.flow
    [flow.hands, flow.wall, flow.discards, flow.melds, flow.flowers, flow.reserve,
     flow.seat, flow.phase, flow.generation, round.window&.responses, round.result&.payments,
     round.added_kong_kind, round.pending_riichi, round.riichi_state &&
       [round.riichi_state.points, round.riichi_state.levels, round.riichi_state.ippatsu,
        round.riichi_state.furiten, round.riichi_state.waits, round.riichi_state.sticks], round.riichi_outcome&.to_h]
  end
end
