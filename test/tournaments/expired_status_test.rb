# encoding: UTF-8
require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/ui'
require_relative '../support/localization'
require_relative '../support/tournament_public_ui'
require_relative '../../lib/tournaments/public_screen'
require_relative '../support/assertions'
include GameRoomTest::Assertions

GameRoomTestLocalization.use_language('en')
ui=TournamentPublicUI
Form.prepend(ui::Script)
rows=[11,22,33].map{|id|ui.publication(id,**{'windows'=>[],'starts_at'=>200,'deadline_at'=>300})}
snapshot=ui.snapshot(rows)
snapshot=Marshal.load(Marshal.dump(snapshot))
snapshot['announcements'].map!{|row|row['__id']==33 ? row.merge('sporting_completed'=>true,'sporting_completed_at'=>250) : row}
before=Marshal.dump(snapshot)
now=299
screen=GameRoomTournaments::PublicScreen.new(program:Object.new,registry:GameRoomGames::CATALOG,
  load:-> {snapshot},join:->(*){raise 'Unexpected registration'},alert:->(message){raise message},
  mode_label:'Server-backed test',actor:ui::ACTOR,clock:-> {now})
ui.script(->(form) {
  list=form.fields.first
  keys=list.instance_variable_get(:@item_keys).dup
  assert_equal(2,keys.size,'Completed tournament stayed in Current')
  list.index=1
  now=300
  screen.send(:render)
  assert_equal(keys,list.instance_variable_get(:@item_keys),'Expiry moved tournaments or changed their order')
  assert_equal(1,list.index,'Expiry moved the selection')
  assert(list.options.all?{|label|label.end_with?('Deadline passed')},'Expired tournament still says in progress')
  filter=ui.field(form,'Show tournaments')
  filter.index=1
  filter.trigger(:move)
  assert_equal([33],list.instance_variable_get(:@item_keys),'Completed contains unresolved expired tournaments')
  assert(list.options.first.include?('Completed — all required matches have been resolved'),'Sporting completion lost its distinct status')
  form.cancel_button.trigger(:press)
}) {screen.run}
assert_equal(before,Marshal.dump(snapshot),'Status rendering rewrote tournament data')
{'en'=>'Deadline passed','pl'=>'Termin minął','cs'=>'Termín uplynul',
  'es'=>'Plazo vencido','ru'=>'Срок истёк'}.each do |language,label|
  GameRoomTestLocalization.use_language(language)
  text=GameRoomTournaments::PublicText.new(registry:GameRoomGames::CATALOG,mode_label:'Server',actor:ui::ACTOR)
  expired=text.lifecycle_label(:running,overdue:true)
  completed=text.lifecycle_label(:completed,overdue:true)
  assert_equal(label,expired,'Deadline status is missing or not translated')
  assert(expired!=completed,'Deadline and sporting completion share a label')
  assert(text.summary(rows.first,snapshot,now:300).include?(expired),'Summary omitted deadline status')
  assert(text.action_header(rows.first,snapshot,now:300).include?(expired),'Action header omitted deadline status')
  assert_equal(expired,text.lifecycle_label(:ended),'Legacy expiry uses a different status')
  manual=ui.publication(44,**{'windows'=>[],'starts_at'=>0,'deadline_at'=>300,'participant_limit'=>2}).merge('registration_closes_at'=>0)
  full=ui.snapshot([manual],[ui.registration(111,tournament_id:44,user:'Alpha'),ui.registration(112,tournament_id:44,user:'Beta')])
  assert(text.action_header(full['announcements'].first,full,now:300).end_with?(label),'A full registration replaced the expired status')
end
puts 'PASS expired status: Current order/focus retained; Completed requires sporting results; list/header/summary agree in five languages without writes'
