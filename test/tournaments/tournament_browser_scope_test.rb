require_relative '../support/ui'
require_relative '../support/tournament_public_ui'
require_relative '../../lib/tournaments/public_screen'
include GameRoomTest::Assertions
T = TournamentPublicUI
GameRoomLocalization.boot(settings:{'interface_language'=>'en','known_languages'=>['en']})
Form.prepend(T::Script)
row=T.publication
own=T.publication(22).merge('__insertion_user'=>T::ACTOR)
done=T.publication(33).merge('sporting_completed'=>true,'sporting_completed_at'=>149)
foreign=T.snapshot([row,done])
mine=T.snapshot([row,own,done])
alerts=[]
[foreign,mine].each do |data|
  T.script(->(form) do
    list=form.fields.first
    assert_equal('My tournaments',list.header)
    assert_equal(data.equal?(mine) ? [22] : [],list.instance_variable_get(:@item_keys))
    assert_equal('You have no tournaments in this view.',list.empty_label)
    filter=T.field(form,'Show tournaments')
    filter.index=1
    filter.trigger(:move)
    assert_equal([],list.options,'Changing view exposed foreign tournaments')
    filter.index=0
    filter.trigger(:move)
    assert_equal(data.equal?(mine) ? [22] : [],list.instance_variable_get(:@item_keys))
    form.cancel_button.trigger(:press)
  end) do
    args=T.arguments(data,clock:-> {150},load:-> {data},mine:true,alert:->(text) {alerts<<text}).reject { |key,_|[:snapshot,:publication].include?(key) }
    GameRoomTournaments::PublicScreen.new(**args).run
  end
end
assert_equal([],alerts,'My tournaments emitted a misleading fallback announcement')
puts 'PASS My tournaments: empty and single-row views remain lists, no fallback, no foreign rows on filter changes'
