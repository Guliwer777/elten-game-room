require_relative '../support/private_card_games'
require_relative '../../games/poker'

game = GameRoomGames::Poker.new
%w[holdem draw].each do |variant|
  h, runners = PrivateCardGamesTest.create(game, users: %w[Alice Bob Carol],
    options: {'variant'=>variant, 'starting_chips'=>100, 'thinking_time'=>600})
  hands = h.users.to_h { |user| [user, h.replay(user).state[:hands][user].dup] }
  # An ordinary call must validate on foreign views without exposing cards.
  actor = h.replay('Alice').current_player
  action = game.legal_actions(h.replay(actor), actor).find { |item| %w[call check].include?(item['action']) }
  PrivateCardGamesTest.submit(h, runners, actor, action)
  PrivateCardGamesTest.assert_private(h)
  h.view('Alice').transfer_ownership(h.view('Alice').participants.find { |p| p.user == 'Carol' })
  runners['Bob'].close
  h.view('Bob').leave
  h.add_client('Bob')
  assert(h.join('Bob'), 'cold return failed')
  runners['Bob'] = runner_for(h, 'Bob')
  assert(h.replay('Bob').state[:hands]['Bob'] == hands['Bob'], 'cold return changed hand')
  PrivateCardGamesTest.tick(h, runners)
  150.times do
    rep = h.replay('Alice')
    break if [:hand_complete, :finished].include?(rep.state[:phase])
    if rep.state[:phase].to_s.start_with?('private_')
      PrivateCardGamesTest.tick(h, runners)
    else
      actor = rep.current_player
      choices = game.legal_actions(h.replay(actor), actor)
      action = if rep.state[:phase] == :exchange
        choices.find { |item| JSON.parse(item['cards']).size == 2 }
      else
        choices.find { |item| item['action'] == 'all_in' } || choices.find { |item| %w[call check].include?(item['action']) }
      end
      assert(action, 'all-in action unavailable')
      PrivateCardGamesTest.submit(h, runners, actor, action)
    end
    PrivateCardGamesTest.assert_private(h)
  end
  state = h.replay('Alice').state
  assert([:hand_complete, :finished].include?(state[:phase]), "#{variant} all-in stuck at #{state[:phase]}")
  assert(state[:stacks].values.sum == 300, 'all-in chips changed')
  assert(h.events('Alice').size == h.replay('Alice').accepted_events.size, 'handover rejected events')
  runners.each_value(&:close)
end

# Folded hands must stay private even when someone else wins the whole pot.
h, runners = PrivateCardGamesTest.create(game, users: %w[Alice Bob Carol])
2.times do
  actor = h.replay('Alice').current_player
  action = game.legal_actions(h.replay(actor), actor).find { |item| item['action'] == 'fold' }
  PrivateCardGamesTest.submit(h, runners, actor, action)
end
assert(h.replay('Alice').state[:phase] == :hand_complete, 'fold did not award pot')
assert(h.events('Alice').none? { |event| event['action'] == 'private_show' }, 'uncontested hands revealed')
PrivateCardGamesTest.assert_private(h)
runners.each_value(&:close)
puts 'PASS private Poker host transfer, cold return, all-in runout, partial exchange and folded-hand secrecy'
