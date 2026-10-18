require_relative '../support/tournament_forfeit_native'
T=GameRoomTournaments
F=TournamentForfeitNative

F.with_fixture do |f|
  f.start
  service=f.services['Alice']
  original=service.send(:read_match_binding,f.candidate,5,f.match,nil)
  # Keep the actual native fixture but add public historical bindings. The
  # observer has no membership in these tables, exactly as in a large list.
  8.times do |index|
    match={'match_id'=>format('%064x',index+1),'leg'=>1,'number'=>index+2,'players'=>%w[alice bob]}
    f.candidate['matches'] << match
    binding=Marshal.load(Marshal.dump(original))
    binding['match_id']=match['match_id']
    binding['players']=service.send(:prepared_match,f.candidate,match)['players']
    binding['session_id']+=index+1
    binding['table']['__id']+=index+1
    binding['table']['__live_session_id']="missing-native-#{index}"
    binding['table']['tournament_match']['match_id']=match['match_id']
    creator=service.send(:creator_document,f.candidate,match,nil,'alice')
    [ ['creator',creator],['binding',binding] ].each do |kind,document|
      key=service.send(:anchor,f.candidate,5,match,kind)
      T::ServerPlanDocument.encode(document,anchor:key).each { |part| f.documents.insert(part) }
    end
    key=service.send(:entry_anchor,f.candidate,5,match,'start',binding)
    start={'kind'=>'ordinary-match-start-v1','schedule_id'=>f.candidate['schedule_id'],'publication_ref'=>f.candidate['publication_ref'],
      'match_id'=>match['match_id'],'leg'=>1,'binding_digest'=>service.send(:binding_digest,binding),'session_id'=>binding['session_id']}
    T::ServerPlanDocument.encode(start,anchor:key).each { |part| f.documents.insert(part) }
  end
  f.h.add_client('Organizer')
  # Organizer role is irrelevant to the read: use a cold observer whose native
  # store is genuinely empty, rather than fabricating game_sessions results.
  outside=f.make_service('Organizer')
  reads=[]
  native_select=f.documents.method(:select)
  f.documents.define_singleton_method(:select) do |**query|
    reads << query
    native_select.call(**query)
  end
  begin
    view=outside.result_view(include_match_status:true)
    assert_equal([],view['forfeitable_matches'])
    assert_equal([],view['cancellable_matches'])
    assert_equal(9,view.fetch('forfeit_unavailable_matches').size)
    assert(reads.size<=8,"Started-match list introduced per-match reads: #{reads.size}")
    assert(reads.any? { |query| (keys=query.dig(:where,'operation_key')).is_a?(Hash) && keys['in']&.size==9 },'Start intents were not read as one batch')
    count=reads.size
    # A supplied, confirmed empty result must not issue its own network read.
    assert_equal(false,outside.send(:read_start_intent,f.candidate,5,f.match,original,rows:[]))
    assert_equal(count,reads.size)
    assert_equal(true,outside.send(:read_start_intent,f.candidate,5,f.match,original))
    assert(reads.size>count,'An absent supplied snapshot was treated as known empty')
    # A failed batch is unknown, never a successful absence observation.
    f.documents.define_singleton_method(:select) do |**query|
      keys=query.dig(:where,'operation_key')
      raise IOError,'start batch unavailable' if keys.is_a?(Hash) && keys['in']&.size==9
      native_select.call(**query)
    end
    assert_raises(IOError) {outside.result_view(include_match_status:true)}
  ensure
    outside.close
  end
end
puts 'PASS batch start evidence: nine native-unavailable matches, bounded shared queries, confirmed empty vs missing read, failed batch remains unknown'
