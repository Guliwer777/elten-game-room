require_relative '../support/tournament_native'
require EltenTestHost.file('src/ui/controls/check_box.rb')
require_relative '../support/assertions'
include GameRoomTest::Assertions
require_relative '../../lib/tournaments/server_forfeit_screen'
require_relative '../../lib/table_voice_screen'
# Constructor pumping only. No keyboard driver, keys or navigation trial.
$native_tutorial_driver=Object.new
$native_tutorial_driver.define_singleton_method(:tick) { |_form| }
GameRoomLocalization.boot(settings:{'interface_language'=>'en','known_languages'=>['en']})
T=GameRoomTournaments
program=Object.new
notices=[]
program.define_singleton_method(:alert) { |message|notices<<message }
policy={order:'higher',winner:1000,loser:0}
names={'a'=>'Alice','b'=>'Bob','c'=>'Carol','d'=>'Dave'}
duel=T::ServerForfeitScreen.new(program:program,names:names,units:%w[a b],policy:policy)
duel.send(:build_form)
fields=duel.instance_variable_get(:@duel_scores)
assert_equal(%w[1000 0],fields.values.map(&:text))
fields['b'].set_text('77')
duel.instance_variable_get(:@loser).tap { |list|list.index=0; list.trigger(:move) }
assert_equal(%w[0 77],fields.values.map(&:text),'Changing the loser discarded explicit small-point editing')
duel.instance_variable_get(:@form).fields.grep(Button).last.press
assert_equal(nil,duel.instance_variable_get(:@result))

multi=T::ServerForfeitScreen.new(program:program,names:names,units:%w[a b c d],policy:policy)
multi.send(:build_form)
list=multi.instance_variable_get(:@list)
flag=multi.instance_variable_get(:@forfeit)
score=multi.instance_variable_get(:@score)
[1,2,3].each do |index|
  list.index=index
  list.trigger(:move)
  multi.instance_variable_get(:@place).index=1
  flag.checked=true
  flag.trigger(:change)
  assert_equal('0',score.text,'Forfeit checkbox did not prefill the losing technical score')
end
form=multi.instance_variable_get(:@form)
form.fields.grep(Button).first.press
decision=multi.instance_variable_get(:@result)
assert_equal([['a'],%w[b c d]],decision.fetch(:places))
assert_equal(%w[b c d],decision.fetch(:forfeits))
assert_equal({'a'=>1000,'b'=>0,'c'=>0,'d'=>0},decision.fetch(:scores))
preview={'kind'=>'ordinary-match-forfeit-v3',
  'summary'=>T::AdministrativeResult.build(units:%w[a b c d],policy:policy,**decision)}
confirmation=T::ServerForfeitScreen::Confirmation.new(program:program,preview:preview,names:names)
confirmation.send(:build_form)
text=confirmation.instance_variable_get(:@form).fields.first.text
assert(text.include?('Alice; tournament points: 6'),'Multiplayer consequences hide the calculated large points')
assert_equal(3,text.scan('tournament points: 0').size)
confirmation.instance_variable_get(:@form).fields.grep(Button).last.press

disabled=T::ServerForfeitScreen.new(program:program,names:names,units:%w[a b],policy:nil)
disabled.send(:build_form)
assert_equal([],disabled.instance_variable_get(:@form).fields.grep(EditBox))
disabled.instance_variable_get(:@form).fields.grep(Button)[1].press
assert_equal({all_zero:true},disabled.instance_variable_get(:@result))
zero={'kind'=>'ordinary-match-forfeit-v3','summary'=>T::AdministrativeResult.build(units:%w[a b],all_zero:true)}
window=T::ServerForfeitScreen::Confirmation.new(program:program,preview:zero,names:names)
window.send(:build_form)
text=window.instance_variable_get(:@form).fields.first.text
assert(text.include?('No winner is recorded.') && text.include?('Alice: 0') && !text.include?('1. Alice'),'No-award confirmation invented places')
window.instance_variable_get(:@form).fields.grep(Button).last.press
assert_equal([],notices)
eight_names=('a'..'h').to_h { |unit| [unit,unit.upcase] }
eight=T::ServerForfeitScreen.new(program:program,names:eight_names,units:eight_names.keys,policy:policy)
eight.send(:build_form)
(1..7).each do |index|
  eight.instance_variable_get(:@list).tap { |field| field.index=index; field.trigger(:move) }
  eight.instance_variable_get(:@place).index=1
  eight.instance_variable_get(:@forfeit).tap { |field| field.checked=true; field.trigger(:change) }
end
eight.instance_variable_get(:@form).fields.grep(Button).first.press
eight_decision=eight.instance_variable_get(:@result)
assert_equal([['a'],('b'..'h').to_a],eight_decision.fetch(:places))
eight_summary=T::AdministrativeResult.build(units:eight_names.keys,policy:policy,**eight_decision)
eight_points=T::Standings.calculate(units:eight_names.keys,
  results:[eight_summary.slice('participants','winners','scores','score_order','places','forfeits','resolution').merge('id'=>'eight')],
  points:T::Standings::MATCH_POINTS)
assert_equal([14,0,0,0,0,0,0,0],eight_points.map { |row| row['points'] })
assert_equal([],notices)
puts 'PASS native control callbacks: short duel, multiplayer places/ties, editable suggestions, cancel and explicit all-zero; no keyboard input'
