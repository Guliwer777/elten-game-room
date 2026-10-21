require_relative '../support/tournament_forfeit_native'
T=GameRoomTournaments
F=TournamentForfeitNative

def complete_native_game(f)
  12.times do
    replay=f.h.replay('Alice')
    break if replay.finished?
    f.h.submit(replay.current_player,f.h.game.legal_actions(replay,replay.current_player).first)
  end
  assert(f.h.replay('Alice').finished?,'Fixture did not finish its native game')
end

F.with_fixture do |f|
  f.start
  service=f.services['Alice']
  stale=f.legacy_preview(loser:'alice')
  forfeit_key=service.send(:anchor,f.candidate,5,f.match,'forfeit')
  parts=T::ServerPlanDocument.encode(stale,anchor:forfeit_key)
  f.documents.insert(parts.first)
  complete_native_game(f)
  binding=service.send(:read_match_binding,f.candidate,5,f.match,nil)
  f.h.as('Alice') {service.collect([binding,f.candidate,5,f.match])}
  accepted=f.services['Bob'].result_view
  assert_equal('ordinary-match-result-v1',accepted['results'].first['kind'])
  assert_equal(['alice'],accepted['results'].first['summary']['winners'])
  # An older in-flight forfeit batch finishes after the genuine result. It
  # cannot replace the sporting cutoff even though no new confirm call occurs.
  parts.drop(1).each { |part| f.documents.insert(part) }
  after=f.services['Bob'].result_view
  assert_equal(accepted['results'],after['results'])
  assert_equal('ordinary-match-result-v1',after.fetch('forfeit_conflicts').first['accepted_kind'])
  assert_equal(nil,service.send(:forfeit_document,f.candidate,5,f.match))
  writes=f.documents.insert_count
  error=assert_raises(T::OrdinaryMatchService::Blocked) {f.confirm(stale)}
  assert_equal(:legacy_forfeit_write_disabled,error.code)
  assert_equal(writes,f.documents.insert_count)
  assert_raises(T::OrdinaryMatchService::Blocked) {f.services['Bob'].entry_status(match_id:f.match['match_id'],leg:1)}
  # Other authorized accounts may confirm the same genuine result. Their
  # later copies and duplicated ACK parts cannot change first completion.
  result_key=service.send(:anchor,f.candidate,5,f.match,'result')
  T::ServerPlanDocument.encode(accepted['results'].first,anchor:result_key).each do |part|
    f.documents.insert_as(part,'Bob')
    f.documents.insert(part)
  end
  cold=f.make_service('Bob')
  begin
    assert_equal(after,cold.result_view)
  ensure
    cold.close
  end
end

F.with_fixture do |f|
  f.start
  service=f.services['Alice']
  preview=f.legacy_preview(loser:'alice')
  accepted=f.insert_historical(preview)
  complete_native_game(f)
  binding=service.send(:read_match_binding,f.candidate,5,f.match,nil)
  ordinary=f.h.as('Alice') do
    T::OrdinaryMatchResults.read(repository:f.h.repositories.fetch('Alice'),
      registry:GameRoomGames::CATALOG,transport:f.h.transports.fetch('Alice'),table:binding['table'],binding:binding)
  end
  assert_equal(['alice'],ordinary['summary']['winners'])
  ordinary=ordinary.merge('publication_ref'=>f.candidate['publication_ref'])
  key=service.send(:anchor,f.candidate,5,f.match,'result')
  parts=T::ServerPlanDocument.encode(ordinary,anchor:key)
  f.documents.insert(parts.first)
  # A partial later ordinary result cannot hide a complete accepted forfeit.
  assert_equal(accepted['results'],f.services['Bob'].result_view['results'])
  parts.drop(1).each { |part| f.documents.insert(part) }
  after=f.services['Bob'].result_view
  assert_equal(accepted['results'],after['results'])
  conflict=after.fetch('forfeit_conflicts').first
  assert_equal('ordinary-match-forfeit-v2',conflict['accepted_kind'])
  assert_equal('ordinary-match-result-v1',conflict['later_attempts'].first['kind'])
  assert_equal(preview,service.send(:forfeit_document,f.candidate,5,f.match))
  writes=f.documents.insert_count
  assert_raises(T::OrdinaryMatchService::Blocked) {f.confirm(preview)}
  assert_equal(writes,f.documents.insert_count,'Accepted cutoff retry duplicated the immutable document')
end

puts 'PASS first complete cross-kind cutoff: ordinary then late forfeit, forfeit then late ordinary, partial reads, cold clients and duplicate receipts'
