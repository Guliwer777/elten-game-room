require_relative '../support/tournament_forfeit_native'
T=GameRoomTournaments
F=TournamentForfeitNative

F.with_fixture do |f|
  before=f.documents.insert_count
  preview=f.preview(loser:'alice')
  assert_equal(before,f.documents.insert_count,'Preview wrote a document')
  assert_equal('unstarted',preview['decision']['basis'])
  assert_equal([['bob'],['alice']],preview['summary']['places'])
  assert_raises(T::OrdinaryMatchService::Blocked) {f.confirm(preview,user:'Bob')}
  altered=Marshal.load(Marshal.dump(preview)); altered['summary']['winners']=['alice']
  assert_raises(T::OrdinaryMatchService::Blocked) {f.confirm(altered)}
  assert_equal(before,f.documents.insert_count)
  view=f.confirm(preview)
  assert_equal(2,view['standings'].find { |row| row['unit']=='bob' }['points'])
  count=f.documents.insert_count
  assert_equal(view,f.confirm(preview),'Accepted same intent changed result')
  assert_equal(count,f.documents.insert_count,'Repeated intent wrote again')
  assert_equal(view,f.services['Bob'].result_view,'Cold second actor saw different result')
end

F.with_fixture(game:GameRoomGames::ThreeFiveEight.new,users:%w[Alice Bob Carol]) do |f|
  preview=f.preview(loser:'bob')
  assert_equal([%w[alice carol],['bob']],preview['summary']['places'])
  view=f.confirm(preview)
  assert_equal({'alice'=>3,'bob'=>0,'carol'=>3},view['standings'].to_h { |row| [row['unit'],row['points']] })
end

F.with_fixture do |f|
  f.start
  preview=f.preview(loser:'alice')
  assert_equal('opponent',preview['decision']['basis'])
  assert(preview.key?('cancelled_game'),'Started match lacks accepted-history boundary')
  before=f.documents.insert_count
  f.h.submit('Alice',f.h.game.legal_actions(f.h.replay('Alice'),'Alice').first)
  error=assert_raises(T::OrdinaryMatchService::Blocked) {f.confirm(preview)}
  assert_equal(:forfeit_preview_changed,error.code)
  assert_equal(before,f.documents.insert_count,'Stale confirmation wrote before re-confirmation')
  fresh=f.preview(loser:'alice')
  f.documents.on_insert=->(row) {raise IOError,'lost full ACK' if row['part_index']==row['part_count']}
  assert_raises(IOError) {f.confirm(fresh)}
  f.documents.on_insert=nil
  pending=f.services['Alice'].operations.find { |entry| JSON.parse(entry['values']['document_json'])['kind']=='ordinary-match-forfeit-v2' }
  count=f.documents.insert_count
  12.times do
    replay=f.h.replay('Alice')
    break if replay.finished?
    f.h.submit(replay.current_player,f.h.game.legal_actions(replay,replay.current_player).first)
  end
  assert(f.h.replay('Alice').finished?,'Fixture failed to finish accepted ordinary gameplay')
  f.services['Alice'].reconcile(pending['id'])
  assert_equal(count,f.documents.insert_count,'Recovered complete ACK wrote again')
  view=f.services['Bob'].result_view
  assert_equal(['bob'],view['results'].first['summary']['winners'],'Later gameplay overwrote accepted cutoff')
  assert_equal('alice',view['results'].first['decision']['loser'])
  assert_equal('alice',view['results'].first['organizer'])
end

F.with_fixture do |f|
  f.start
  preview=f.preview
  f.documents.on_insert=->(row) {raise IOError,'lost incomplete ACK' if row['part_index']==0}
  assert_raises(IOError) {f.confirm(preview)}
  f.documents.on_insert=nil
  pending=f.services['Alice'].operations.find { |entry| JSON.parse(entry['values']['document_json'])['kind']=='ordinary-match-forfeit-v2' }
  count=f.documents.insert_count
  f.h.submit('Alice',f.h.game.legal_actions(f.h.replay('Alice'),'Alice').first)
  assert_raises(T::OrdinaryMatchService::Blocked) {f.services['Alice'].reconcile(pending['id'])}
  assert_equal(count,f.documents.insert_count,'Uncertain incomplete stale preview resumed writing')
end
puts 'PASS native forfeit v2: read-only preview, organizer/identity validation, stale consent, explicit placements, full and incomplete ACK recovery, later finish preserves cutoff'
