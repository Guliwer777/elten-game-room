require_relative '../support/tournament_public_service'
require_relative '../../lib/tournaments/public_service'
require_relative '../../lib/tournaments/server_match_window'
require_relative '../../lib/tournaments/schedule_candidate'
include TournamentPublicServiceSupport
include GameRoomTest::Assertions
T=GameRoomTournaments

hours={'start'=>'22:00','end'=>'02:00','utc_offset_minutes'=>120}
stamp=->(day,hour,minute=0){Time.utc(2026,10,day,hour,minute).to_i}
candidate={'starts_at'=>stamp.call(16,19),'windows'=>[],'daily_hours'=>hours}
assert_equal({'opens'=>stamp.call(16,20),'closes'=>stamp.call(17,0)},T::ServerMatchWindow.current(candidate,stamp.call(16,23)))
assert_equal(:outside_window,assert_raises(T::Publication::Invalid){T::ServerMatchWindow.current(candidate,stamp.call(17,0))}.code)
assert_equal(:outside_window,assert_raises(T::Publication::Invalid){T::ServerMatchWindow.current(candidate,stamp.call(16,19,59))}.code)
assert_equal({'opens'=>stamp.call(17,20),'closes'=>stamp.call(18,0)},T::ServerMatchWindow.current(candidate,stamp.call(17,20)))
candidate['starts_at']=stamp.call(16,21)
assert_equal(stamp.call(16,21),T::ServerMatchWindow.current(candidate,stamp.call(16,22))['opens'])
assert_equal(:tournament_not_started,assert_raises(T::Publication::Invalid){T::ServerMatchWindow.current(candidate,stamp.call(16,20))}.code)
daytime={'start'=>'09:30','end'=>'11:00','utc_offset_minutes'=>-300}
assert_equal({'opens'=>stamp.call(17,14,30),'closes'=>stamp.call(17,16)},T::TournamentTiming.daily_window(daytime,stamp.call(17,15)))
assert_equal(nil,T::TournamentTiming.daily_window(daytime,stamp.call(17,16)))
[hours.merge('start'=>'24:00'),hours.merge('end'=>'22:00'),hours.merge('utc_offset_minutes'=>121),hours.merge('extra'=>true)].each do |invalid|
  assert_equal(:invalid_playing_hours,assert_raises(T::Publication::Invalid){T::TournamentTiming.validate_daily_hours!(invalid)}.code)
end
sandbox do |c|
  publication=T::Publication.from_draft(**params(draft:draft.merge('windows'=>[],'starts_at'=>200,'deadline_at'=>0,'daily_hours'=>hours),
    registration_opens_at:100,registration_closes_at:200,timezone:'UTC').reject{|key,_|key==:intent_id},registry:GameRoomGames::CATALOG,publication_key:'daily').to_row
  assert_equal(hours,JSON.parse(publication['schedule_json'])['daily_hours'])
  c.service.publish(**params(draft:draft.merge('windows'=>[],'starts_at'=>200,'deadline_at'=>0,'daily_hours'=>hours)))
  c.service.join(tournament_id:1)
  c.actor='Bob'
  service=c.service(journal:c.reopen_journal)
  service.join(tournament_id:1)
  row=service.list['announcements'].first
  c.now=200
  result=service.schedule_candidate(publication_ref:{'author'=>row['__insertion_user'],'publication_key'=>row['publication_key']}).to_h
  assert_equal(hours,result['daily_hours'],'Published playing hours were lost in the actual match candidate')
  assert_raises(T::Publication::Invalid){T::ServerMatchWindow.current(result,stamp.call(17,1))}
  assert_equal(stamp.call(17,20),T::ServerMatchWindow.current(result,stamp.call(17,21))['opens'])
end
puts 'PASS daily hours: midnight, fixed zones, half-open boundaries, start guard and validation'
