require_relative '../support/tournament_forfeit_native'
T=GameRoomTournaments
# Published v2 receipts retain their old interpretation. Fixture insertion is
# deliberately not a call to a newly re-enabled production writer.
[
  [GameRoomGames::TicTacToe.new,%w[Alice Bob],false],
  [GameRoomGames::TicTacToe.new,%w[Alice Bob],true],
  [GameRoomGames::ThreeFiveEight.new,%w[Alice Bob Carol],false]
].each do |game,users,started|
  TournamentForfeitNative.with_fixture(game:game,users:users) do |f|
    f.start if started
    before=f.documents.insert_count
    preview=f.legacy_preview(loser:'alice')
    assert_equal(before,f.documents.insert_count,'Historical fixture construction wrote a record')
    assert_equal('ordinary-match-forfeit-v2',preview['kind'])
    assert_equal(started ? 'opponent' : 'unstarted',preview['decision']['basis'])
    error=assert_raises(T::OrdinaryMatchService::Blocked) { f.confirm(preview) }
    assert_equal(:legacy_forfeit_write_disabled,error.code)
    assert_equal(before,f.documents.insert_count)
    view=f.insert_historical(preview)
    assert_equal([preview],view['results'])
    assert_equal(0,view['standings'].find { |row|row['unit']=='alice' }['points'])
    assert(view['standings'].all? { |row|row['score_for'].nil? },'Historical v2 gained new technical scores')
    cold=f.make_service(users.last)
    begin
      assert_equal(view,cold.result_view)
    ensure
      cold.close
    end
  end
end
puts 'PASS immutable historical v2 receipts and classifications; current writer refuses all old v2 intents'
