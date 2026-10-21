require_relative '../support/tournament_forfeit_native'
T=GameRoomTournaments
F=TournamentForfeitNative

F.with_fixture do |f|
  stale=f.preview
  f.documents.on_insert=->(row) {raise IOError,'lost header ACK' if row['part_index']==0}
  assert_raises(IOError) {f.confirm(stale)}
  f.documents.on_insert=nil
  old=f.services['Alice'].operations.find { |row| JSON.parse(row['values']['document_json'])['kind']=='ordinary-match-forfeit-v3' }
  original=f.documents.rows.map(&:dup)
  f.h.as('Alice') { f.services['Alice'].open_match(match_id:f.match['match_id'],leg:1) }
  writes=f.documents.insert_count
  error=assert_raises(T::OrdinaryMatchService::Blocked) {f.services['Alice'].reconcile(old['id'])}
  assert_equal(:forfeit_preview_changed,error.code)
  assert_equal(writes,f.documents.insert_count)
  assert_equal([],f.services['Bob'].result_view['results'],'Incomplete attempt was counted as a result')
  assert(f.services['Bob'].entry_status(match_id:f.match['match_id'],leg:1)['binding'],'Incomplete attempt blocked entry')
  fresh=f.preview
  assert(stale!=fresh,'Fixture did not change the accepted history')
  assert_equal(writes,f.documents.insert_count,'Fresh preview wrote without consent')
  accepted=f.confirm(fresh)
  assert_equal(fresh,accepted['results'].first)
  assert_equal(original,f.documents.rows.first(original.size),'Recovery mutated existing immutable parts')
  cold=f.make_service('Bob')
  begin
    assert_equal(accepted,cold.result_view,'Cold client could not recover the newly confirmed decision')
  ensure
    cold.close
  end
  # A previous batch may have been in flight when the newer attempt completed.
  # Late old chunks must not change the already accepted sporting cutoff.
  key=old['values'].slice(*T::ServerPlanArchive::ANCHOR_FIELDS)
  T::ServerPlanDocument.encode(stale,anchor:key).drop(1).each { |part| f.documents.insert(part) }
  view=f.services['Bob'].result_view
  assert_equal([fresh],view['results'],'Late completion of an older partial attempt changed the result')
  conflicts=view.fetch('forfeit_conflicts')
  assert_equal(1,conflicts.size,'Conflicting complete attempt was silently hidden')
  assert_equal(f.match['match_id'],conflicts.first['match_id'])
  writes=f.documents.insert_count
  error=assert_raises(T::OrdinaryMatchService::Blocked) {f.services['Alice'].reconcile(old['id'])}
  assert_equal(:conflicting_document,error.code)
  assert_equal(writes,f.documents.insert_count)
end

F.with_fixture do |f|
  # Same snapshot is still the same explicit intent, so a retry can finish it.
  preview=f.preview
  f.documents.on_insert=->(row) {raise IOError,'partial ACK' if row['part_index']==0}
  assert_raises(IOError) {f.confirm(preview)}
  f.documents.on_insert=nil
  first=f.documents.rows.first.dup
  view=f.confirm(preview)
  assert_equal(preview,view['results'].first)
  assert_equal(first,f.documents.rows.first)
  assert_equal(1,f.services['Alice'].operations.count { |row| JSON.parse(row['values']['document_json'])['kind']=='ordinary-match-forfeit-v3' })
end

F.with_fixture do |f|
  # Two overlapping immutable batches can complete in a different order from
  # their headers. Server row IDs, never local read/time ordering, choose first.
  a=f.preview(loser:'alice')
  b=f.preview(loser:'bob')
  service=f.services['Alice']
  key=service.send(:anchor,f.candidate,5,f.match,'forfeit')
  a_parts=T::ServerPlanDocument.encode(a,anchor:key)
  b_parts=T::ServerPlanDocument.encode(b,anchor:key)
  f.documents.insert(a_parts.first)
  b_parts.each { |part| f.documents.insert(part) }
  a_parts.drop(1).each { |part| f.documents.insert(part) }
  view=f.services['Bob'].result_view
  assert_equal([b],view['results'],'First header incorrectly won over first complete receipt')
  assert_equal(1,view.fetch('forfeit_conflicts').size)
  # Identical retry rows cannot move the immutable first-completion boundary.
  a_parts.each { |part| f.documents.insert(part) }
  b_parts.each { |part| f.documents.insert(part) }
  assert_equal(view,f.services['Bob'].result_view)
  writes=f.documents.insert_count
  error=assert_raises(T::OrdinaryMatchService::Blocked) {f.confirm(a)}
  assert_equal(:conflicting_document,error.code)
  assert_equal(writes,f.documents.insert_count)
end

F.with_fixture do |f|
  preview=f.preview
  key=f.services['Alice'].send(:anchor,f.candidate,5,f.match,'forfeit')
  header=T::ServerPlanDocument.encode(preview,anchor:key).first
  f.documents.insert_as(header,'Bob')
  assert_equal([],f.services['Alice'].result_view['results'],'Other account could create an organizer attempt')
  f.documents.insert(header.merge('payload'=>'not-empty'))
  assert_raises(T::Publication::Invalid) {f.preview}
  assert_raises(T::Publication::Invalid) {f.services['Bob'].result_view}
end

F.with_fixture do |f|
  preview=f.preview
  f.documents.on_insert=->(row) {raise IOError,'partial before ordinary result' if row['part_index']==0}
  assert_raises(IOError) {f.confirm(preview)}
  f.documents.on_insert=nil
  f.start
  12.times do
    replay=f.h.replay('Alice')
    break if replay.finished?
    f.h.submit(replay.current_player,f.h.game.legal_actions(replay,replay.current_player).first)
  end
  assert(f.h.replay('Alice').finished?,'Fixture failed to finish normal gameplay')
  service=f.services['Alice']
  binding=service.send(:read_match_binding,f.candidate,5,f.match,nil)
  f.h.as('Alice') {service.collect([binding,f.candidate,5,f.match])}
  view=f.services['Bob'].result_view
  assert_equal('ordinary-match-result-v1',view['results'].first['kind'],'Incomplete forfeit suppressed the real result')
  writes=f.documents.insert_count
  error=assert_raises(T::OrdinaryMatchService::Blocked) {f.confirm(preview)}
  assert_equal(:result_already_recorded,error.code)
  assert_equal(writes,f.documents.insert_count,'Old partial forfeit rewrote natural completion')
end

[
  ->(parts) {[parts.last.merge('payload'=>'???')]},
  ->(parts) {[parts.first,parts.last.merge('part_count'=>2)]},
  ->(parts) {[parts.first.merge('document_digest'=>'not-a-digest')]}
].each do |malformed|
  F.with_fixture do |f|
    preview=f.preview
    key=f.services['Alice'].send(:anchor,f.candidate,5,f.match,'forfeit')
    malformed.call(T::ServerPlanDocument.encode(preview,anchor:key)).each { |row| f.documents.insert(row) }
    assert_raises(T::Publication::Invalid) {f.services['Bob'].result_view}
  end
end
puts 'PASS forfeit attempts: fresh consent after partial write, same-intent retry, cold client, immutable chunks, first complete cutoff, explicit conflicts and malformed partial denial'
