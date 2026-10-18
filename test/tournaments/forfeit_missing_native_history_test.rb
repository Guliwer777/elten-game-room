require_relative '../support/tournament_forfeit_native'
T=GameRoomTournaments
F=TournamentForfeitNative

F.with_fixture(game:GameRoomGames::ThreeFiveEight.new,users:%w[Alice Bob Carol]) do |f|
  f.start
  service=f.services['Alice']
  binding=service.send(:read_match_binding,f.candidate,5,f.match,nil)
  assert(service.send(:read_start_intent,f.candidate,5,f.match,binding),'Fixture lacks native start intent')
  f.h.as('Alice') { service.instance_variable_get(:@lobby).close_table(f.h.table) }
  writes=f.documents.insert_count
  error=assert_raises(T::OrdinaryMatchService::Blocked) {f.preview(loser:'carol')}
  assert_equal(:game_state_unavailable,error.code)
  view=f.services['Bob'].result_view(include_match_status:true)
  assert_equal([],view['results'])
  assert_equal([],view['forfeitable_matches'],'Lost history was mislabeled as never started')
  assert_equal([],view['cancellable_matches'],'Lost history falsely offered scored termination')
  assert_equal(writes,f.documents.insert_count)
end

F.with_fixture do |f|
  service=f.services['Alice']
  table=f.h.as('Alice') {service.open_match(match_id:f.match['match_id'],leg:1)}
  # A start request can have committed even when its acknowledgement is lost.
  # The retained intent alone is enough to refuse a fabricated unstarted result.
  f.h.as('Alice') {service.start_parameters(table,players:f.h.users)}
  writes=f.documents.insert_count
  error=assert_raises(T::OrdinaryMatchService::Blocked) {f.preview}
  assert_equal(:game_state_unavailable,error.code)
  view=service.result_view(include_match_status:true)
  assert_equal([],view['forfeitable_matches'])
  assert_equal([],view['cancellable_matches'])
  assert_equal(writes,f.documents.insert_count)
end

F.with_fixture do |f|
  service=f.services['Alice']
  table=f.h.as('Alice') {service.open_match(match_id:f.match['match_id'],leg:1)}
  f.h.as('Alice') {service.instance_variable_get(:@lobby).close_table(table)}
  preview=f.preview
  assert_equal('unstarted',preview['decision']['basis'],'A confirmed never-started table was incorrectly treated as lost game history')
end
puts 'PASS missing native history: accepted start and uncertain start cannot become unstarted forfeit; genuinely never-started table remains supported'
