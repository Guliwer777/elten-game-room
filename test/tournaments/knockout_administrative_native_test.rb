require_relative '../support/tournament_forfeit_native'
require_relative '../../lib/tournaments/server_phase_plan'
T=GameRoomTournaments

[false,true].each do |rematch|
  TournamentForfeitNative.with_fixture do |f|
    names=%w[alice bob carol dave eve frank grace heidi]
    plan=T::KnockoutRound.build(seeds:names,players_per_match:2,round_number:1)
    metadata=plan.slice('seeds','round','players_per_match','generation').merge(
      'phase_digest'=>'e'*64,'parent_plan_digest'=>'f'*64)
    metadata['rematch']=true if rematch
    candidate=f.candidate
    candidate.merge!('format'=>'knockout','roster'=>names,'knockout'=>metadata,'rematch'=>rematch)
    candidate['schedule_id'],candidate['matches']=T::KnockoutSchedule.matches(metadata:metadata,generation:candidate['roster_generation'])
    service=f.services.fetch('Alice')
    zero_match=candidate['matches'].first
    zero=service.forfeit_preview(match_id:zero_match['match_id'],leg:zero_match['leg'],
      expected_schedule_id:candidate['schedule_id'],all_zero:true)
    service.confirm_forfeit(preview:zero)
    covered=rematch ? candidate['matches'][1] : nil
    if covered
      error=assert_raises(T::OrdinaryMatchService::Blocked) { service.open_match(match_id:covered['match_id'],leg:covered['leg']) }
      assert_equal(:result_already_recorded,error.code)
      assert_raises(T::OrdinaryMatchService::Blocked) do
        service.forfeit_preview(match_id:covered['match_id'],leg:covered['leg'],expected_schedule_id:candidate['schedule_id'],all_zero:true)
      end
    end
    candidate['matches'].drop(rematch ? 2 : 1).each do |match|
      preview=service.forfeit_preview(match_id:match['match_id'],leg:match['leg'],
        expected_schedule_id:candidate['schedule_id'],loser:match['players'].last)
      service.confirm_forfeit(preview:preview)
    end
    view=service.result_view(include_match_status:true)
    assert_equal(candidate['matches'].size-(rematch ? 1 : 0),view['results'].size,'An unplayed leg became a fabricated receipt')
    assert_equal(rematch ? 1 : 0,view.fetch('settled_without_play',[]).size)
    assert_equal('ready_next_round',view['knockout_state'])
    document=T::ServerPhasePlan.build(candidate:candidate,results:view['results'])
    following=document.fetch('candidate')
    next_plan=T::KnockoutRound.from_metadata(following['knockout'])
    assert_equal(['carol'],next_plan['byes'],'The wrong opponent received the vacant pairing')
    assert_equal([%w[eve grace]],next_plan['matches'].map { |row|row['participants'] })
    assert_equal(view,f.services.fetch('Bob').result_view(include_match_status:true))
  end
end

TournamentForfeitNative.with_fixture do |f|
  c=f.candidate
  metadata=T::KnockoutSchedule.direct_metadata(seeds:c['roster'],generation:c['roster_generation'],publication_digest:c['publication_digest'],rematch:true)
  c.merge!('format'=>'knockout','knockout'=>metadata,'rematch'=>true)
  c['schedule_id'],c['matches']=T::KnockoutSchedule.matches(metadata:metadata,generation:c['roster_generation'])
  m=c['matches'].first
  preview=f.services['Alice'].forfeit_preview(match_id:m['match_id'],leg:m['leg'],expected_schedule_id:c['schedule_id'],all_zero:true)
  view=f.services['Alice'].confirm_forfeit(preview:preview)
  assert_equal(true,view['completed'])
  assert_equal(nil,view['champion'])
  assert_equal([0,0],view['standings'].map { |row|row['points'] })
  error=assert_raises(T::Publication::Invalid) { T::ServerPhasePlan.build(candidate:c,results:view['results']) }
  assert_equal(:tournament_completed,error.code)
end
puts 'PASS native no-award receipts, return-leg closure without invented results, correct bracket bye, cold read and final without champion'
