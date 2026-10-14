require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/ui'
require_relative '../support/tournament_public_ui'
require_relative '../../lib/tournaments/public_screen'
GameRoomLocalization.boot(settings:{'interface_language'=>'en','known_languages'=>['en']})
Form.prepend(TournamentPublicUI::Script)
u=TournamentPublicUI
class CategoryMenu
  attr_reader :actions
  def initialize;@actions={};end
  def option(label,*_args,&block);@actions[label]=block;end
end
now=Time.utc(2026,10,13,12).to_i
make=->(id,date,start,ending,opens,closes){u.publication(id).merge('timezone'=>'UTC',
  'schedule_json'=>JSON.generate({'windows'=>[{'date'=>date,'start'=>start,'end_date'=>date,'end'=>ending}]}),
  'registration_opens_at'=>opens,'registration_closes_at'=>closes)}
running=make.call(11,'2026-10-13','10:00','14:00',now-3*86400,now-3*3600).merge('__insertion_user'=>u::ACTOR)
registration=make.call(22,'2026-10-14','10:00','14:00',now-3*3600,now+21*3600).merge('__insertion_user'=>u::ACTOR)
waiting=make.call(33,'2026-10-14','10:00','14:00',now-3*86400,now-3600)
old=make.call(44,'2026-10-10','10:00','14:00',100,200)
recent=make.call(55,'2026-10-12','10:00','14:00',100,200)
rows=[running,registration,waiting,old,recent]
members=[u.registration(77,tournament_id:33,time:waiting['registration_opens_at']+60)]
current=u.snapshot(rows,members)
edits=[];joins=[];alerts=[]
args=u.arguments(current,load:->{current},join:->(id){joins<<id;u.record('confirmed',tournament_id:id)},alert:->(message){alerts<<message}).reject{|key,_|[:publication,:snapshot].include?(key)}
u.script(->(form){
  lists=form.fields.grep(ListBox)
  assert_equal(%w[Ongoing\ tournaments Tournament\ registrations Ended\ tournaments],lists.map(&:header))
  assert_equal([11,33],lists[0].instance_variable_get(:@item_keys))
  assert_equal([22],lists[1].instance_variable_get(:@item_keys))
  assert_equal([55,44],lists[2].instance_variable_get(:@item_keys))
  assert_equal(0,form.index)
  unavailable=CategoryMenu.new;lists[0].context(unavailable,false)
  assert((unavailable.actions.keys & ['Join tournament','Leave tournament','Edit tournament','Delete tournament']).empty?,'Running tournament exposes unavailable participant or organizer actions')
  form.define_singleton_method(:game_room_invitation_context?){true}
  ordered=CategoryMenu.new;lists[0].context(ordered,false)
  assert_equal('Accept invitation',ordered.actions.keys.last,'Invitation is not the last tournament context action')
  form.singleton_class.remove_method(:game_room_invitation_context?)
  menu=CategoryMenu.new;lists[1].context(menu,false)
  assert(menu.actions.key?('Join tournament'),'Registration context lacks Join')
  assert(menu.actions.key?('Edit tournament') && menu.actions.key?('Delete tournament'),'Organizer context lacks administration')
  menu.actions['Edit tournament'].call
  assert_equal([22],edits)
  lists[0].index=1
  other=CategoryMenu.new;lists[0].context(other,false)
  assert(other.actions.key?('Leave tournament'),'Registered participant lacks withdrawal')
  assert(!other.actions.key?('Edit tournament') && !other.actions.key?('Delete tournament'),'Participant sees organizer-only actions')
  current=u.snapshot(rows.map{|row|row['__id']==22 ? row.merge('title'=>'Changed before menu click') : row},members)
  menu.actions['Join tournament'].call
  assert_equal([],joins,'Old context menu joined changed rules/title')
  assert_equal(1,alerts.size)
  now+=3*3600
  u.button(form,'Refresh').trigger(:press)
  assert_equal([33],lists[0].instance_variable_get(:@item_keys))
  assert_equal([11,55,44],lists[2].instance_variable_get(:@item_keys),'Finished tournament did not move automatically on refresh')
  form.cancel_button.trigger(:press)
}) do
  GameRoomTournaments::PublicScreen.new(**args,clock:->{now},withdraw:->(_id){raise 'Unexpected withdrawal'},
    join_virtual:->(*){raise 'Unexpected virtual registration after tournament start'},
    edit_tournament:->(row){edits<<row['__id']},delete_tournament:->(_row){raise 'Unexpected delete'}).run
end
puts 'PASS categorized browser: initial focus, newest-ended order, owner-only context, withdrawal, stale-menu refusal and timed category migration'
