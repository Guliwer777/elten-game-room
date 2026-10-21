require_relative '../support/tournament_forfeit_native'
T=GameRoomTournaments
TournamentForfeitNative.with_fixture do |f|
  f.start
  service=f.services['Alice']
  before=f.documents.insert_count
  error=assert_raises(T::OrdinaryMatchService::Blocked) {f.preview(loser:'alice')}
  assert_equal(:match_in_progress,error.code)
  assert_equal([],service.result_view(include_match_status:true)['cancellable_matches'])
  assert_equal(before,f.documents.insert_count)
  12.times do
    replay=f.h.replay('Alice')
    break if replay.finished?
    f.h.submit(replay.current_player,f.h.game.legal_actions(replay,replay.current_player).first)
  end
  assert(f.h.replay('Alice').finished?,'Native fixture did not finish')
  preview=f.preview(loser:'alice')
  assert_equal('ended',preview['boundary']['status'])
  f.documents.on_insert=->(row) {raise IOError,'lost complete administrative ACK' if row['part_index']==row['part_count']}
  assert_raises(IOError) {f.confirm(preview)}
  f.documents.on_insert=nil
  pending=service.operations.find { |row|JSON.parse(row['values']['document_json'])['kind']=='ordinary-match-forfeit-v3' }
  writes=f.documents.insert_count
  service.reconcile(pending['id'])
  assert_equal(writes,f.documents.insert_count)
  view=f.services['Bob'].result_view
  assert_equal({'alice'=>0,'bob'=>2},view['standings'].to_h { |row|[row['unit'],row['points']] })
  binding=service.instance_variable_get(:@bindings).fetch(f.h.table['__id'])
  service.collect(binding)
  assert_equal(writes,f.documents.insert_count,'An already settled completed game wrote another result')
  assert_equal(view,f.services['Bob'].result_view)
  assert(f.h.replay('Alice').finished?,'Administrative result changed completed game history')
end
puts 'PASS no sporting cancellation during play; completed unresolved game settlement, full ACK recovery and immutable result'
