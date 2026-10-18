require_relative '../../games/mahjong_support/solitaire_game'
require_relative '../../games/mahjong_support/solitaire_presentation'

module MahjongGameTest
  class Game < GameRoomGames::Base
    include GameRoomGames::MahjongSolitaireGame
    include GameRoomGames::MahjongSolitairePresentation
    def id; 'mahjong'; end
    def name; 'Mahjong'; end
    def minimum_players; 1; end
    def maximum_players; 1; end
    def option_definitions
      [GameRoomGames::OptionDefinition.new(key: 'layout', kind: :choice, label: 'Layout', default: 'terraces',
        choices: %w[terraces flat].map { |value| GameRoomGames::OptionChoice.new(value: value, label: value) })]
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
      @calls += 1
      raise 'Unexpected solitaire random request' unless count == 8 && sides == 256
      Roll.new(values: [1, 2, 3, 4, 5, 6, 7, 8])
    end
  end

  def mahjong_event(number, command, actor: 'Alice')
    {'id'=>number, 'action'=>command.action, 'value'=>command.value, 'actor'=>actor}
  end

  def mahjong_snapshot(state)
    board = state[:board]
    state.merge(board: board && [board.positions, board.tiles, board.remaining])
  end
end
