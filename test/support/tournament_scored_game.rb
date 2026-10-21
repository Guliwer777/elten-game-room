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
      def tournament_small_point_policy(options:)
        tournament_target_small_points(100)
      end
      def participant_scores(replay)
        tournament_export_scores(replay, options: {})
      end
    end
    if lower
      game.define_method(:tournament_export_small_scores) do |replay, options:|
        {scores: replay.players.to_h { |player| [player, player == replay.winner ? 1 : 9] }, order: 'lower'}
      end
      game.define_method(:tournament_small_point_policy) { |options:| tournament_target_small_points(100, order: 'lower') }
      game.define_method(:participant_scores) { |replay| tournament_export_small_scores(replay, options: {})[:scores] }
    end
    GameRoomGames::Registry.new([game])
  end
end
