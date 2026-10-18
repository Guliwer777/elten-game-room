require_relative '../support/private_card_games'
%w[spades tysiac three_five_eight].each { |name| require_relative "../../games/#{name}" }

[GameRoomGames::Spades, GameRoomGames::Tysiac, GameRoomGames::ThreeFiveEight].each do |klass|
  game = klass.new
  h, runners = PrivateCardGamesTest.create(game, users: %w[Alice Bob Carol])
  forged = false
  180.times do
    rep = h.replay('Alice')
    break if rep.state[:private_error]
    assert(!rep.finished? && rep.state[:phase] != :round_complete, 'fixture finished without detecting illegal play')
    if rep.state[:phase].to_s.start_with?('private_')
      PrivateCardGamesTest.tick(h, runners)
      next
    end
    actor = rep.current_player
    mine = h.replay(actor)
    state = mine.state
    actions = game.legal_actions(mine, actor).reject { |action| action['action'] == 'surrender' }
    if !forged && state[:phase] == :playing && state[:current_trick].any?
      illegal = (state[:hands][actor] - game.send(:legal_cards, state, actor)).first
      if illegal
        receipt = GameRoomPrivateCardLedger.locate(state, actor, illegal)
        if receipt
          value = game.id == 'tysiac' ? "normal|#{illegal}" : illegal
          selection = game.id == 'three_five_eight' ? {'action'=>'play','card'=>value} : {'kind'=>'card','action'=>'select','card'=>value}
          assert(game.action_for(selection, mine, actor).first != :ok, 'honest client allows illegal suit')
          # Even a real native receipt must not make an illegal round official.
          command = GameRoomPrivateCards.command('play', value, operation: 'reveal', **receipt)
          h.write(actor, [command])
          forged = true
          next
        end
      end
    end
    PrivateCardGamesTest.submit(h, runners, actor, actions.first)
  end
  assert(forged, "#{game.id}: no illegal-suit fixture")
  h.users.each do |user|
    rep = h.replay(user)
    assert(rep.state[:private_error] == :invalid_round, "#{game.id}: invalid round not detected")
    assert(!rep.finished? && rep.winner.nil?, "#{game.id}: invalid round exposed official winner")
    assert(rep.state[:scores].values.all?(&:zero?), "#{game.id}: invalid score counted")
  end
  runners.each_value(&:close)
end
puts 'PASS shared private round audit: native proof does not bypass suit rules or publish an invalid result'
