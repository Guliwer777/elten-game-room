require_relative '../support/tournament_forfeit_native'
T=GameRoomTournaments
F=TournamentForfeitNative
F.with_fixture do |f|
  preview=f.preview(loser:'alice')
  assert_equal('ordinary-match-forfeit-v3',preview['kind'])
  assert_equal('unbound',preview['boundary']['status'])
  assert_equal([['bob'],['alice']],preview['summary']['places'])
  before=f.documents.insert_count
  assert_raises(T::OrdinaryMatchService::Blocked) { f.confirm(preview,user:'Bob') }
  forged=T::Publication::Data.copy(preview)
  forged['summary']['winners']=['alice']
  assert_raises(T::OrdinaryMatchService::Blocked) { f.confirm(forged) }
  assert_equal(before,f.documents.insert_count)
  view=f.confirm(preview)
  assert_equal({'alice'=>0,'bob'=>2},view['standings'].to_h { |r|[r['unit'],r['points']] })
  assert_equal(view,f.services['Bob'].result_view)
  before=f.documents.insert_count
  f.confirm(preview)
  f.services['Alice'].reconcile(f.services['Alice'].operations.first['id'])
  assert_equal(before,f.documents.insert_count,'Repeated accepted settlement wrote again')
end
F.with_fixture(game:GameRoomGames::MilleBornes.new,users:%w[Alice Bob Carol Dave]) do |f|
  args={match_id:f.match['match_id'],leg:1,expected_schedule_id:f.candidate['schedule_id'],
    places:[['alice'],%w[bob carol dave]],forfeits:%w[bob carol dave],
    scores:{'alice'=>5000,'bob'=>0,'carol'=>0,'dave'=>0}}
  preview=f.h.as('Alice') { f.services['Alice'].forfeit_preview(**args) }
  view=f.confirm(preview)
  assert_equal({'alice'=>6,'bob'=>0,'carol'=>0,'dave'=>0},view['standings'].to_h { |r|[r['unit'],r['points']] })
  assert_equal(5000,view['standings'].find { |r|r['unit']=='alice' }['score_for'])
  assert_equal(view,f.services['Dave'].result_view)
end
F.with_fixture do |f|
  f.start
  error=assert_raises(T::OrdinaryMatchService::Blocked) { f.preview }
  assert_equal(:match_in_progress,error.code)
  error=assert_raises(T::OrdinaryMatchService::Blocked) do
    f.h.as('Alice') { f.services['Alice'].forfeit_preview(match_id:f.match['match_id'],leg:1,
      expected_schedule_id:f.candidate['schedule_id'],all_zero:true) }
  end
  assert_equal(:match_in_progress,error.code)
end
F.with_fixture do |f|
  preview=f.h.as('Alice') { f.services['Alice'].forfeit_preview(match_id:f.match['match_id'],leg:1,
    expected_schedule_id:f.candidate['schedule_id'],all_zero:true) }
  view=f.confirm(preview)
  assert_equal(true,view['completed'])
  assert_equal([0,0],view['standings'].map { |r|r['points'] })
  assert_equal('all_zero',view['results'].first['summary']['resolution'])
end
puts 'PASS native administrative receipts, multiplayer points, second account, idempotency and refusal to interrupt active play'
