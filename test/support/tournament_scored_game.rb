require_relative '../../games/tic_tac_toe'
require_relative '../../games/registry'
module TournamentScoredGameSupport
  module_function
  def registry(lower: false)
    game = Class.new(GameRoomGames::TicTacToe) do
      def id; 'future_scored_game'; end
      def tournament_export_scores(replay, options:)
        replay.players.to_h { |player| [player, player == replay.winner ? 10 : 3] }
      end
    end
    if lower
      game.define_method(:tournament_export_small_scores) do |replay, options:|
        {scores: replay.players.to_h { |player| [player, player == replay.winner ? 1 : 9] }, order: 'lower'}
      end
    end
    GameRoomGames::Registry.new([game])
  end
end
