require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/ui'
require_relative '../support/tournament_public_ui'
require_relative '../../lib/tournaments/tournament_setup_editor'
require_relative '../support/assertions'
include GameRoomTest::Assertions
GameRoomLocalization.boot(settings:{'interface_language'=>'en','known_languages'=>['en']})
Form.prepend(TournamentPublicUI::Script)
u=TournamentPublicUI
published=[]; messages=[]
editor=GameRoomTournaments::TournamentSetupEditor.new(program:Object.new,registry:GameRoomGames::CATALOG,
  configure:->(_game,options){options},clock:->{Time.local(2026,10,13,15).to_i},alert:->(message){messages<<message},
  publish:->(**values){published<<values;{'status'=>'confirmed'}})
u.script(->(form){game=u.field(form,'Game');game.index=GameRoomGames::CATALOG.ids.index('tic_tac_toe');game.trigger(:select)},
  ->(form){
    assert_equal(%w[No Yes],u.field(form,'Return matches').options)
    assert_equal(0,u.field(form,'Return matches').index)
    assert_equal('16',u.field(form,'Participant limit (maximum 128)').text)
    u.field(form,'Tournament name').text='First to wins'
    format=u.field(form,'Tournament format');format.index=1;format.trigger(:move)
    mode=u.field(form,'Return matches in knockout rounds');mode.index=2;mode.trigger(:move)
    u.field(form,'Wins required in knockout rounds').text='2'
    final=u.field(form,'Return match in the final');final.index=2;final.trigger(:move)
    u.field(form,'Wins required in the final').text='3'
    form.accept_button.trigger(:press)
  }){editor.wait}
assert_equal([],messages)
assert_equal(2,published.first[:draft]['knockout_wins_to'])
assert_equal(3,published.first[:draft]['final_wins_to'])
assert_equal(false,published.first[:draft]['knockout_rematch'])
assert_equal(false,published.first[:draft]['final_rematch'])
puts 'PASS setup keeps first-to-wins out of round robin/groups and persists separate knockout/final targets'
