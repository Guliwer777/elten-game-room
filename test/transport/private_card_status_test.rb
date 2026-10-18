require_relative '../support/private_card_games'
require_relative '../../games/poker'
require_relative '../../games/four_in_a_row'
require_relative '../../games/tic_tac_toe'
require_relative '../../lib/game_surfaces/specifications'

game = GameRoomGames::Poker.new
h, runners = PrivateCardGamesTest.create(game, users: %w[Alice Bob])
replay = h.replay('Alice')
original = Marshal.load(Marshal.dump(replay.state))
[:private_prepare, :private_wait, :private_dealing, :private_draw, :private_show].each do |phase|
  replay.state[:phase] = phase
  spec = game.surface_spec(replay, 'Alice')
  assert(spec.is_a?(GameSurfaces::PawnTrackSpec), "#{phase}: no shared waiting surface")
  assert(spec.items.size == 1 && !spec.items.first.action, "#{phase}: waiting surface allows an action")
  expected = phase == :private_show ? 'Waiting for players to reveal their cards.' : 'Waiting for all players to receive their cards.'
  assert(spec.items.first.label == expected, "#{phase}: wrong status")
  assert(game.current_turn_shortcut_text(replay, 'Alice') == expected, "#{phase}: shortcut disagrees")
  assert(game.legal_actions(replay, 'Alice').empty?, "#{phase}: public hand action while waiting")
end
replay.state.replace(original)
assert(game.surface_spec(replay, 'Alice').id == 'poker_actions', 'normal betting surface replaced')
replay.state[:private_error] = :pool_limit
assert(game.surface_spec(replay, 'Alice').items.first.label.include?('server limit'), 'pool limit not explained')
runners.each_value(&:close)
%w[FourInARow TicTacToe].each do |type|
  board_game = GameRoomGames.const_get(type).new
  board_harness = NativeRoomHarness.new(game:board_game, users:%w[Alice Bob])
  board_harness.start
  board = board_harness.replay('Alice')
  assert(board.state.nil?, "#{type}: fixture is not a state-less board replay")
  assert(board_game.save_game_error(board).nil?, "#{type}: ordinary board save was blocked")
  assert(board_game.participant_replacement_error(board, player:'Bob').nil?, "#{type}: ordinary board replacement was blocked")
end
puts 'PASS shared private-card waiting and error surfaces, shortcuts and normal hand restoration'
