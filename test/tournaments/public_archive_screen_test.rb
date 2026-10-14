require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/ui'
require_relative '../support/tournament_public_ui'
require_relative '../../lib/tournaments/public_screen'
GameRoomLocalization.boot(settings: {'interface_language'=>'en','known_languages'=>['en']})
T = TournamentPublicUI
Form.prepend(T::Script)
old = T.publication(11).merge('timezone'=>'UTC')
recent = T.publication(22).merge('timezone'=>'UTC', 'schedule_json'=>JSON.generate({'windows'=>[{'date'=>'2026-10-25','start'=>'18:00','end_date'=>'2026-10-25','end'=>'21:00'}]}))
latest=T.publication(33).merge('timezone'=>'UTC','schedule_json'=>JSON.generate({'windows'=>[{'date'=>'2026-10-20','start'=>'18:00','end_date'=>'2026-10-20','end'=>'20:00'}]}))
snapshot=T.snapshot([old,recent,latest])
T.script(->(form) {
  list=form.fields.first
  assert_equal([22],list.instance_variable_get(:@item_keys))
  ended=T.field(form,'Ended tournaments')
  assert_equal([33,11],ended.instance_variable_get(:@item_keys))
  assert(ended.options.first.include?('Ended'),'Missing ended label')
  ended.index=1
  form.index=form.fields.index(ended)
  form.accept_button.trigger(:press)
  assert_equal([33,11],ended.instance_variable_get(:@item_keys))
  form.cancel_button.trigger(:press)
}, ->(form) {
  assert(T.field(form,'Tournament details').text.include?('Próba 11'), 'Archive selected a wrong snapshot row')
  form.cancel_button.trigger(:press)
}) do
  args=T.arguments(snapshot).reject{|key,_| [:publication,:snapshot].include?(key)}
  GameRoomTournaments::PublicScreen.new(**args,clock: -> {Time.utc(2026,10,20,21).to_i}).run
end
puts 'PASS three category lists: all ended retained newest first and correct canonical preview ID from ended category'
