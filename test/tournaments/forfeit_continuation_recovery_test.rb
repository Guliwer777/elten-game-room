require_relative '../support/tournament_presence_native'
T=GameRoomTournaments
TournamentForfeitNative.with_fixture(game:GameRoomGames::Farkle.new,users:%w[Alice Bob Carol Dave]) do |f|
  f.start
  service=f.services.fetch('Alice')
  old=f.legacy_preview(loser:'bob')
  assert_equal('ordinary-match-elimination-v1',old['kind'])
  anchor=service.send(:anchor,f.candidate,5,f.match,'forfeit')
  journal=service.instance_variable_get(:@journal)
  pending=journal.prepare(kind:'plan_document',intent_id:'historical-continuation',
    values:anchor.merge('kind'=>'plan_document','document_json'=>JSON.generate(old)))
  native_before=f.h.core.entries.size
  table_before=f.documents.insert_count
  [-> {f.confirm(old)},-> {service.reconcile(pending['id'])}].each do |operation|
    error=assert_raises(T::OrdinaryMatchService::Blocked,&operation)
    assert_equal(:legacy_forfeit_write_disabled,error.code)
  end
  assert_equal(native_before,f.h.core.entries.size,'A retained old manual continuation wrote native history')
  assert_equal(table_before,f.documents.insert_count,'A retained old decision wrote a result')
  assert_equal(%w[Alice Bob Carol Dave],f.h.game.tournament_active_players(f.h.replay('Alice'),options:f.candidate['game_options']))
end
puts 'PASS retired manual continuation intents cannot be confirmed or resumed; automatic absence uses its separate native mechanism'
