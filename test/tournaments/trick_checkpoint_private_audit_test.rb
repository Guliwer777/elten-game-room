require_relative '../support/trick_game_checkpoint'

[GameRoomGames::Spades.new, GameRoomGames::Tysiac.new].each do |game|
  TournamentForfeitNative.with_fixture(game: game, users: %w[Alice Bob Carol],
      options: game.default_options.merge('score_limit'=>10_000, 'bot_delay'=>0)) do |f|
    f.start
    h = f.h
    runners = h.users.to_h { |user| [user, runner_for(h, user)] }
    assert_equal({'status'=>'none'}, TrickGameCheckpointTest.checkpoint(h))
    forged = false
    120.times do
      replay = h.replay('Alice')
      break if replay.state[:private_error]
      assert(replay.state[:phase] != :round_complete, 'Invalid fixture completed a legal deal instead')
      if replay.state[:phase].to_s.start_with?('private_') || replay.state[:phase] == :awaiting_deal
        PrivateCardGamesTest.tick(h, runners)
        next
      end
      actor = replay.current_player
      mine = h.replay(actor)
      if !forged && mine.state[:phase] == :playing && !mine.state[:current_trick].empty?
        illegal = (mine.state[:hands][actor] - game.send(:legal_cards, mine.state, actor)).find do |card|
          GameRoomPrivateCardLedger.locate(mine.state, actor, card)
        end
        if illegal
          receipt = GameRoomPrivateCardLedger.locate(mine.state, actor, illegal)
          value = game.id == 'tysiac' ? "normal|#{illegal}" : illegal
          assert(game.action_for({'kind'=>'card', 'action'=>'select', 'card'=>value}, mine, actor).first != :ok)
          # A modified client can truthfully reveal its own card out of suit;
          # the full private audit, not this test, must reject the completed deal.
          h.write(actor, [GameRoomPrivateCards.command('play', value, operation: 'reveal', **receipt)])
          forged = true
          next
        end
      end
      action = game.legal_actions(mine, actor).find { |item| item['action'] != 'surrender' }
      assert(action, "No remaining action in #{mine.state[:phase]}")
      PrivateCardGamesTest.submit(h, runners, actor, action)
    end
    assert(forged, "#{game.id}: did not reach an authenticated off-suit reveal")
    h.users.each do |user|
      replay = h.replay(user)
      assert_equal(:invalid_round, replay.state[:private_error])
      assert(!replay.state.key?(:tournament_checkpoint), 'Rejected private scoring published a checkpoint')
      assert_equal({'status'=>'unsupported'}, TrickGameCheckpointTest.checkpoint(h, user))
    end
    before = f.documents.insert_count
    error = assert_raises(GameRoomTournaments::OrdinaryMatchService::Blocked) { f.preview }
    assert_equal(:game_state_unavailable, error.code)
    assert_equal(before, f.documents.insert_count, 'Rejected private deal produced an administrative result')
  ensure
    runners&.each_value(&:close)
  end
end

# Surrender is a legitimate, fully scored Tysiac deal. It must not require
# disclosing any unplayed private cards merely to make its checkpoint available.
game = GameRoomGames::Tysiac.new
TournamentForfeitNative.with_fixture(game: game, users: %w[Alice Bob Carol],
    options: game.default_options.merge('score_limit'=>10_000, 'bot_delay'=>0)) do |f|
  f.start
  h = f.h
  runners = h.users.to_h { |user| [user, runner_for(h, user)] }
  replay = TrickGameCheckpointTest.play_round(h, runners, surrender: true)
  assert_equal('surrender', replay.accepted_events.last['action'])
  assert_equal(:round_complete, replay.state[:phase])
  assert_equal(replay.state[:scores], TrickGameCheckpointTest.checkpoint(h)['scores'])
  assert(replay.state[:hands].values.any? { |cards| cards.any? { |card| GameRoomPrivateCardLedger.hidden?(card) } },
    'Surrender exposed all private hands')
  assert_equal('scored_round', f.preview['decision']['basis'])
ensure
  runners&.each_value(&:close)
end
puts 'PASS private Spades/Tysiac checkpoint audit: truthful illegal reveal gives no checkpoint/result; legitimate private surrender scores without exposing hands'
