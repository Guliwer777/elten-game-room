require_relative '../../support/native_room_harness'
require_relative '../../../games/mahjong'
require_relative '../../../lib/participant_menu'

[['solitaire', 1], ['hong_kong', 4], ['riichi', 4], ['riichi', 3], ['mcr', 4]].each do |variant, seats|
  game = GameRoomGames::Mahjong.new
  options = game.normalize_options('variant'=>variant, 'riichi_seats'=>seats.to_s)
  [0, seats - 1].uniq.each do |bots|
    h = NativeRoomHarness.new(game: game, users: ['Alice'], options: options, bots: bots)
    h.as('Alice') do
      lobby = LobbyRepository.new(ProgramDouble.new(h.broker.endpoint('Alice')), transport: h.transports['Alice'])
      room = lobby.snapshot_for(h.table)
      actions = GameRoomParticipantMenu.management_actions(room: room, game: game, active: false, viewer: 'Alice', owner: 'Alice')
      assert(actions.include?(:add_bot) == (variant != 'solitaire' && bots + 1 < seats), 'bot menu ignored selected Mahjong seats')
      replacements = GameRoomParticipantMenu.replacement_candidates(room: room, players: ['Alice'], participant: 'Alice', game: game)
      assert(replacements.include?(:new_bot) == (variant != 'solitaire'), 'Solitaire offered an unsupported bot replacement')
      assert(game.validation_error(options, player_count: bots + 1).nil? == (bots + 1 == seats), 'start accepted wrong Mahjong roster')
      lobby.close_table(h.table)
    end
  end
end
puts 'PASS Mahjong lobby: selected seat limits, ordinary bot menu, no Solitaire bot replacement and exact start roster'
