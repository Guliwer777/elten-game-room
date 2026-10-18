require_relative '../support/private_card_games'
require_relative '../../games/three_five_eight'
require_relative '../../lib/tournaments/game_result'

game = GameRoomGames::ThreeFiveEight.new
h, runners = PrivateCardGamesTest.create(game,users:%w[Alice Bob Carol])
begin
  forged = false
  180.times do
    replay = h.replay('Alice')
    break if replay.state[:private_error]
    assert(!replay.finished? && replay.state[:phase] != :round_complete,'Fixture never exercised the invalid round')
    if replay.state[:phase].to_s.start_with?('private_')
      PrivateCardGamesTest.tick(h,runners)
      next
    end
    actor = replay.current_player
    mine = h.replay(actor)
    if !forged && mine.state[:phase] == :playing && mine.state[:current_trick].any?
      bad = (mine.state[:hands][actor] - game.send(:legal_cards,mine.state,actor)).first
      receipt = GameRoomPrivateCardLedger.locate(mine.state,actor,bad) if bad
      if receipt
        assert(game.action_for({'action'=>'play','card'=>bad},mine,actor).first != :ok,'Honest move validation accepted a revoke')
        h.write(actor,[GameRoomPrivateCards.command('play',bad,operation:'reveal',**receipt)])
        forged = true
        next
      end
    end
    PrivateCardGamesTest.submit(h,runners,actor,game.legal_actions(mine,actor).first)
  end
  assert(forged,'Fixture failed to submit a genuine off-suit native reveal')
  players = h.users.map { |name| {'username'=>name,'account'=>name.downcase,'team'=>nil} }
  h.users.each do |user|
    snapshot = h.repositories.fetch(user).snapshot_for(h.session)
    replay = game.replay(snapshot.session,snapshot.events,h.repositories.fetch(user))
    assert_equal(:invalid_round,replay.state[:private_error])
    assert(!replay.finished?,'Rejected round has an official winner')
    assert(replay.state[:scores].values.all?(&:zero?),'Rejected round kept provisional scores')
    assert(!GameRoomTournaments::GameResult.valid_replay_history?(replay,snapshot.events),
      'An accepted reveal is not proof that its private round was legal')
    export = lambda do |value|
      GameRoomTournaments::GameResult.from_replay(game:game,replay:value,players:players,
        options:game.options_from_json(snapshot.session.fetch('options')),event_count:snapshot.events.size,
        events:snapshot.events,result_policy:GameRoomTournaments::GameResult::CURRENT_RESULT_POLICY)
    end
    assert_raises(GameRoomTournaments::Publication::Invalid) {export.call(replay)}
    # Defense in depth against a stale/corrupt terminal projection: a winner
    # flag cannot override the actual round audit failure.
    terminal = replay.dup
    terminal.winner = h.users.first
    assert_raises(GameRoomTournaments::Publication::Invalid) {export.call(terminal)}
    assert_equal(snapshot.events,h.events(user),'Validation mutated evidence')
  end
  puts 'PASS actual native private-round failure: authenticated off-suit proof cannot export a result, retain provisional scores or override the audit with a winner flag'
ensure
  runners.each_value(&:close)
end
