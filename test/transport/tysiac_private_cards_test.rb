require_relative '../support/private_card_games'
require_relative '../../games/tysiac'

[[2, {'variant'=>'two_players'}], [2, {'variant'=>'two_players', 'talon_size'=>2, 'last_trick_talon'=>false}], [3, {}],
 [4, {'variant'=>'four_players'}], [4, {'variant'=>'teams'}]].each do |count, options|
  game = GameRoomGames::Tysiac.new
  h, runners = PrivateCardGamesTest.create(game, users: Array.new(count) { |i| "Player#{i}" }, options: options)
  state = h.replay(h.users.first).state
  assert(state[:phase] == :bidding, "opening stalled: #{state[:phase]}")
  assert(state[:talon].empty? && state[:talons].flatten.empty?, 'future talon leaked')
  PrivateCardGamesTest.assert_private(h)
  90.times do
    state = h.replay(h.users.first).state
    break if [:round_complete, :finished].include?(state[:phase])
    if state[:phase].to_s.start_with?('private_')
      PrivateCardGamesTest.tick(h, runners)
      next
    end
    user = state[:current_player]
    mine = h.replay(user)
    legal = game.legal_actions(mine, user)
    # Exercise real transfers and playing, not the shortcut of surrendering.
    selection = legal.reject { |item| item['action'] == 'surrender' }.first
    assert(selection, "no action in #{state[:phase]} for #{user}")
    PrivateCardGamesTest.submit(h, runners, user, selection)
    PrivateCardGamesTest.assert_private(h)
    h.users.each { |viewer| game.surface_spec(h.replay(viewer), viewer) }
  end
  state = h.replay(h.users.first).state
  assert([:round_complete, :finished].include?(state[:phase]), "round failed: #{state[:phase]} #{state[:private_error]}")
  assert(h.events(h.users.first).size == h.replay(h.users.first).accepted_events.size, 'unaccepted event')
  assert(h.users.map { |user| h.replay(user).state[:scores] }.uniq.size == 1, 'different scores')
  runners.each_value(&:close)
end
puts 'PASS Tysiac private hands: 2/3/4, resting seat, teams, talon, transfers, cards and scoring'
