require_relative '../support/private_card_games'
require_relative '../../games/makao'

game = GameRoomGames::Makao.new
covered = Hash.new(0)
[%w[Alice Bob Carol], %w[Alice Bob], %w[A B C D E F G H]].each_with_index do |users, variant|
  options = variant == 0 ? {'profile'=>'joker'} : {'profile'=>'custom', 'hand_size'=>variant == 1 ? 15 : 5,
    'allow_playable_draw'=>false, 'jokers'=>true, 'jack_requests_rank'=>true, 'queen_universal'=>true,
    'attacking_kings'=>true}
  assert(!game.options_error(game.normalize_options(options), player_count:users.size), 'invalid test options')
  h, runners = PrivateCardGamesTest.create(game, users:users, options:options, random_values:Array.new(16, 8))
  PrivateCardGamesTest.assert_private(h)
  transferred = returned = false
  650.times do |index|
    PrivateCardGamesTest.tick(h, runners)
    PrivateCardGamesTest.assert_private(h)
    replay = h.replay(users.first)
    break if replay.finished?
    if index == 15
      h.view(users.first).transfer_ownership(h.view(users.first).participants.find { |entry| entry.user == users.last })
      transferred = true
      next
    end
    if index == 20
      expected = h.replay(users[1]).state[:hands][users[1]].dup
      runners[users[1]].close
      h.view(users[1]).leave
      h.add_client(users[1])
      assert(h.join(users[1]), 'return failed')
      runners[users[1]] = runner_for(h, users[1])
      assert(h.replay(users[1]).state[:hands][users[1]] == expected, 'return changed hand')
      returned = true
      next
    end
    next if replay.state[:phase].to_s.start_with?('private_')
    actor = replay.current_player
    assert(actor, "Makao lost its actor in variant #{variant} at #{index}: #{replay.state.reject { |key, _| %i[private_values private_pools private_draws].include?(key) }.inspect}")
    mine = h.replay(actor)
    choices = game.legal_actions(mine, actor)
    assert(choices.any?, "no Makao move: #{mine.state[:phase]}")
    choice = choices.max_by { |action| game.bot_action_score(mine, actor, action) }
    # Let catches occur as well as declarations.
    if choice['action'] == 'makao' && variant == 1
      other = (users - [actor]).find { |player| game.legal_actions(h.replay(player), player).any? { |action| action['action'] == 'catch' } }
      actor, choice = other, {'kind'=>'command', 'action'=>'catch'} if other
    end
    covered[choice['action']] += 1
    covered['packet'] += 1 if choice['cards'] && JSON.parse(choice['cards']).size > 1
    PrivateCardGamesTest.submit(h, runners, actor, choice)
    assert(h.replay(users.first).accepted_events.size == h.events(users.first).size, 'valid move/proof rejected')
  end
  final = h.replay(users.first)
  assert(final.finished?, 'private Makao did not finish')
  assert(transferred && returned, 'lifecycle fixture too short')
  covered['recycle'] += final.state[:recycle]
  puts "Makao variant #{variant} finished: #{final.accepted_events.size} events, #{final.state[:recycle]} recycles"
  PrivateCardGamesTest.assert_private(h)
  assert(final.accepted_events.size == h.events(users.first).size, 'final private event rejected')
  h.users.each { |user| game.surface_spec(h.replay(user), user) }
  runners.each_value(&:close)
end
%w[play draw packet recycle catch].each { |kind| assert(covered[kind] > 0, "not exercised: #{kind}") }
puts "PASS private Makao: shared continuation, hidden draws, packets, catches, recycling, host/return; #{covered.inspect}"
