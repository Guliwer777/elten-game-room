require_relative '../support/private_card_games'
require_relative '../../games/poker'

game = GameRoomGames::Poker.new
[%w[holdem 2], %w[holdem 8], %w[draw 3], %w[draw 8]].each do |variant, count|
  users = Array.new(count.to_i) { |i| "Player#{i}" }
  h, runners = PrivateCardGamesTest.create(game, users: users,
    options: {'variant'=>variant, 'draw_five'=>true, 'starting_chips'=>1000, 'thinking_time'=>600})
  PrivateCardGamesTest.assert_private(h)
  assert(h.replay(users.first).state[:phase] == :betting, 'initial delivery stalled')
  expected_counts = variant == 'holdem' ? 2 : 5
  assert(users.all? { |user| h.replay(user).state[:hands][user].size == expected_counts }, 'wrong hand size')
  200.times do
    rep = h.replay(users.first)
    break if [:hand_complete, :finished].include?(rep.state[:phase])
    if rep.state[:phase].to_s.start_with?('private_')
      PrivateCardGamesTest.tick(h, runners)
    else
      user = rep.current_player
      choices = game.legal_actions(h.replay(user), user)
      choice = if rep.state[:phase] == :exchange
        choices.max_by { |item| JSON.parse(item['cards']).size }
      else
        choices.find { |item| %w[check call].include?(item['action']) }
      end
      assert(choice, "no move #{rep.state[:phase]}")
      PrivateCardGamesTest.submit(h, runners, user, choice)
    end
    PrivateCardGamesTest.assert_private(h)
  end
  state = h.replay(users.first).state
  assert(state[:phase] == :hand_complete, "#{variant}/#{count}: stalled at #{state[:phase]} / #{state[:private_error]}")
  assert(state[:stacks].values.sum == 1000 * users.size, 'chips not conserved')
  assert(state[:hands].values.flatten.none? { |card| GameRoomPrivateCardLedger.hidden?(card) }, 'showdown incomplete')
  assert(state[:community].size == (variant == 'holdem' ? 5 : 0), 'community card count')
  assert(h.replay(users.first).accepted_events.size == h.events(users.first).size, 'rejected event')
  if variant == 'draw' && count == '8'
    assert(state[:recycle] > 0, 'eight-player full exchange did not recycle')
  end
  runners.each_value(&:close)
end
puts 'PASS private Poker: Holdem, draw, eight players, replacement recycling and full showdowns'
