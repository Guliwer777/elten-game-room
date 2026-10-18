require_relative '../support/tournament_forfeit_native'
require_relative '../support/private_card_games'
T=GameRoomTournaments

TournamentForfeitNative.with_fixture(game:GameRoomGames::ThreeFiveEight.new,users:%w[Alice Bob Carol]) do |f|
  f.start
  h=f.h
  before=f.preview(loser:'bob')
  assert_equal('no_scored_round',before['decision']['basis'])
  assert_equal([%w[alice carol],['bob']],before['summary']['places'])
  runners=h.users.to_h { |user| [user,runner_for(h,user)] }
  h.view('Alice').transfer_ownership(h.view('Alice').participants.find { |player| player.user=='Carol' })
  16.times {PrivateCardGamesTest.tick(h,runners)}
  180.times do
    r=h.replay('Alice')
    break if r.state[:phase]==:round_complete
    if r.state[:phase].to_s.start_with?('private_')
      PrivateCardGamesTest.tick(h,runners)
      next
    end
    actor=r.current_player
    action=h.game.legal_actions(h.replay(actor),actor).first
    assert(action,"No real private move in #{r.state[:phase]}")
    PrivateCardGamesTest.submit(h,runners,actor,action)
  end
  r=h.replay('Alice')
  assert_equal(:round_complete,r.state[:phase])
  assert_equal(h.events('Alice').length,r.accepted_events.length)
  assert(!r.state[:private_error],'Private round audit failed')
  checkpoint=h.game.tournament_scored_checkpoint(r,options:h.game.default_options)
  assert_equal('scored',checkpoint['status'])
  assert_equal(r.state[:scores],checkpoint['scores'])
  # Preserve the original full roster; selecting even the score leader as the
  # loser cannot improve their administrative place by keeping their score.
  loser=r.state[:scores].max_by { |_name,score| score }.first.downcase
  preview=f.preview(loser:loser)
  assert_equal('scored_round',preview['decision']['basis'])
  assert_equal(r.players.map(&:downcase).sort,preview['summary']['participants'])
  assert_equal(r.state[:scores].transform_keys(&:downcase),preview['summary']['scores'])
  assert_equal([loser],preview['summary']['places'].last)
  assert_equal('Carol',h.transports['Carol'].room_snapshot(h.table)[:table]['owner'])
  view=f.confirm(preview) # Organizer Alice is deliberately not the native host.
  assert_equal(0,view['standings'].find { |row| row['unit']==loser }['points'])
  assert_equal(preview['summary'],f.services['Bob'].result_view['results'].first['summary'])
ensure
  runners&.each_value(&:close)
end

# Categories now owns a supported 3-to-2 continuation. A preview must not
# invent a final result; success requires the exact accepted native event.
TournamentForfeitNative.with_fixture(game:GameRoomGames::Categories.new,users:%w[Alice Bob Carol]) do |f|
  f.start
  h=f.h
  count=f.documents.insert_count
  entries=h.core.entries.size
  before=h.replay('Alice')
  preview=f.preview
  assert_equal('ordinary-match-elimination-v1',preview['kind'])
  assert_equal({'loser'=>'carol','mode'=>'continue','basis'=>'continued','checkpoint'=>{'status'=>'none'}},preview['decision'])
  assert(preview.key?('continued_game') && !preview.key?('cancelled_game') && !preview.key?('summary'),
    'Continuing preview invented a terminal result')
  assert_equal(entries,h.core.entries.size,'Read-only continuation preview changed native history')
  assert_equal(count,f.documents.insert_count,'Read-only continuation preview wrote a result')
  view=f.confirm(preview)
  assert(view['results'].empty?,'Continuation ended the tournament match')
  h.users.each do |user|
    replay=h.replay(user)
    assert_equal(before.players,replay.players,'Continuation changed the original result roster')
    assert_equal(before.state[:scores],replay.state[:scores],'Continuation changed completed scores')
    assert_equal([['Carol']],replay.state[:tournament_eliminations])
    assert_equal(%w[Alice Bob],h.game.tournament_active_players(replay,options:f.candidate['game_options']))
    assert_equal(1,replay.accepted_events.count { |event| event['__tournament_elimination']==true },
      'Confirmation did not produce exactly one accepted elimination')
    assert(!replay.finished?,'Continuation fabricated a normal game winner')
  end
  accepted_entries=h.core.entries.size
  f.confirm(preview)
  assert_equal(accepted_entries,h.core.entries.size,'Repeated confirmation duplicated the elimination')
  assert_equal(count,f.documents.insert_count,'Continuation wrote a terminal result document')
end

# Preserve the original refusal contract with a real game that has no
# approved multiplayer continuation/checkpoint adapter.
TournamentForfeitNative.with_fixture(game:GameRoomGames::ScientificWar.new,users:%w[Alice Bob Carol]) do |f|
  f.start
  count=f.documents.insert_count
  entries=f.h.core.entries.size
  error=assert_raises(T::OrdinaryMatchService::Blocked) {f.preview}
  assert_equal(:tournament_continuation_unsupported,error.code)
  assert_equal(count,f.documents.insert_count,'Unsupported continuation wrote a terminal result')
  assert_equal(entries,f.h.core.entries.size,'Unsupported preview changed native history')
end

TournamentForfeitNative.with_fixture(game:GameRoomGames::ThreeFiveEight.new,users:%w[Alice Bob Carol]) do |f|
  f.start
  h=f.h
  runners=h.users.to_h { |user| [user,runner_for(h,user)] }
  16.times {PrivateCardGamesTest.tick(h,runners)}
  forged=false
  180.times do
    r=h.replay('Alice')
    break if r.state[:private_error]
    assert(r.state[:phase]!=:round_complete,'Invalid fixture unexpectedly completed a legal deal')
    if r.state[:phase].to_s.start_with?('private_')
      PrivateCardGamesTest.tick(h,runners)
      next
    end
    actor=r.current_player
    mine=h.replay(actor)
    if !forged && mine.state[:phase]==:playing && mine.state[:current_trick].any?
      illegal=(mine.state[:hands][actor]-h.game.send(:legal_cards,mine.state,actor)).first
      receipt=GameRoomPrivateCardLedger.locate(mine.state,actor,illegal) if illegal
      if receipt
        assert(h.game.action_for({'action'=>'play','card'=>illegal},mine,actor).first!=:ok)
        h.write(actor,[GameRoomPrivateCards.command('play',illegal,operation:'reveal',**receipt)])
        forged=true
        next
      end
    end
    PrivateCardGamesTest.submit(h,runners,actor,h.game.legal_actions(mine,actor).first)
  end
  assert(forged,'Private fixture did not exercise a real off-suit reveal')
  h.users.each do |user|
    r=h.replay(user)
    assert_equal(:invalid_round,r.state[:private_error])
    assert_equal({'status'=>'unsupported'},h.game.tournament_scored_checkpoint(r,options:h.game.default_options),
      'Rejected private deal exposed its pre-audit scoring checkpoint')
  end
  count=f.documents.insert_count
  error=assert_raises(T::OrdinaryMatchService::Blocked) {f.preview}
  # An inconsistent private round fails before interpreting its checkpoint.
  assert_equal(:game_state_unavailable,error.code)
  assert_equal(count,f.documents.insert_count)
ensure
  runners&.each_value(&:close)
end
puts 'PASS native 3-5-8 scored forfeit: private deal/audit, new host, original roster/scores, loser last, organizer independent from host; Categories continues, unsupported continuation and invalid private deals fail closed'
