require_relative '../support/tournament_forfeit_native'
require_relative '../support/private_card_games'
T = GameRoomTournaments

TournamentForfeitNative.with_fixture(game: GameRoomGames::ThreeFiveEight.new, users: %w[Alice Bob Carol]) do |fixture|
  fixture.start
  h = fixture.h
  runners = h.users.to_h { |user| [user, runner_for(h, user)] }
  begin
    16.times { PrivateCardGamesTest.tick(h, runners) }
    forged = false
    180.times do
      replay = h.replay('Alice')
      break if replay.state[:private_error]
      assert(!replay.finished? && replay.state[:phase] != :round_complete, 'Fixture did not reach an invalid private round')
      if replay.state[:phase].to_s.start_with?('private_')
        PrivateCardGamesTest.tick(h, runners)
        next
      end
      actor = replay.current_player
      mine = h.replay(actor)
      if !forged && mine.state[:phase] == :playing && mine.state[:current_trick].any?
        wrong = (mine.state[:hands][actor] - h.game.send(:legal_cards, mine.state, actor)).first
        receipt = GameRoomPrivateCardLedger.locate(mine.state, actor, wrong) if wrong
        if receipt
          h.write(actor, [GameRoomPrivateCards.command('play', wrong, operation: 'reveal', **receipt)])
          forged = true
          next
        end
      end
      PrivateCardGamesTest.submit(h, runners, actor, h.game.legal_actions(mine, actor).first)
    end
    assert(forged, 'Fixture never sent an authenticated off-suit receipt')
    writes = fixture.documents.insert_count
    history = h.events('Alice')
    h.users.each do |user|
      service = fixture.services.fetch(user)
      snapshot = h.repositories.fetch(user).snapshot_for(h.session)
      replay = h.game.replay(snapshot.session, snapshot.events, h.repositories.fetch(user))
      assert_equal(:invalid_round, replay.state[:private_error])
      terminal = replay.dup
      terminal.winner = user
      assert_equal(false, service.observe(h.table, snapshot.session, terminal, snapshot.events),
        'A fabricated winner bypassed the private audit at the completion queue')
      error = service.take_error
      assert(error.is_a?(T::Publication::Invalid), 'Private failure was silently queued as a terminal result')
      assert(service.operations.none? { |row| JSON.parse(row.fetch('values').fetch('document_json'))['kind'] == 'ordinary-match-result-v1' },
        'Invalid private result reached the durable publication journal')
      view = service.result_view(include_match_status: true)
      assert(view['results'].empty? && view['forfeitable_matches'].empty? && view['cancellable_matches'].empty?,
        'Invalid private evidence was presented as an ordinary result or safe organizer cutoff')
      assert_equal([fixture.match.slice('match_id', 'leg')], view['forfeit_unavailable_matches'])
    end
    error = assert_raises(T::OrdinaryMatchService::Blocked) { fixture.preview }
    assert_equal(:game_state_unavailable, error.code)
    assert_equal(writes, fixture.documents.insert_count, 'Private audit refusal wrote a result/forfeit')
    assert_equal(history, h.events('Alice'), 'Private audit refusal rewrote native evidence')
  ensure
    runners.each_value(&:close)
  end
end

puts 'PASS private audit/service boundary: genuine illegal native reveal blocks completion queue, result journal, result view and organizer cutoff without rewriting history'
