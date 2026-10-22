if ARGV.first
  ENV['ELTEN_TEST_NATIVE_CONTROLS'] = '1'
  require_relative '../support/binary_rules_load'
end
require_relative '../support/tournament_control_callbacks'
require_relative '../support/tournament_public_ui'
require_relative '../../lib/tournaments/participant_manager'
require_relative '../../lib/tournaments/tournament_invite_picker'
require_relative '../../lib/tournaments/operations_screen'
include GameRoomTest::Assertions
T = GameRoomTournaments
GameRoomLocalization.boot(settings:{'interface_language'=>'en','known_languages'=>['en']})
row = TournamentPublicUI.publication(game:'spades',options:{'team_size'=>2},**{'players_per_match'=>4})
actor = row['__insertion_user']
members = %w[Alpha Beta Gamma Delta].map { |name| {'tournament_id'=>11,'account'=>name.downcase,'username'=>name} }
data = {'announcements'=>[row], 'members'=>members, 'pairs'=>[], 'invitations'=>[
  {'tournament_id'=>11,'account'=>'pending','username'=>'PendingPerson','status'=>'pending'},
  {'tournament_id'=>11,'account'=>'declined','username'=>'DeclinedPerson','status'=>'declined'}]}
calls, alerts, confirmations = [], [], []
program = Object.new
program.define_singleton_method(:usermenu) { |name| calls << [:user,name] }
program.define_singleton_method(:run_network_task) { |*, **, &operation| operation.call }
workspace = Object.new
workspace.define_singleton_method(:load) { data }
workspace.define_singleton_method(:registry) { GameRoomGames::CATALOG }
workspace.define_singleton_method(:set_partner) { |*args|calls << [:pair,*args]; {'status'=>'confirmed'} }
workspace.define_singleton_method(:remove_participant) do |_, account|
  calls << [:remove, account]
  data['members']=data['members'].reject { |person|person['account']==account }
  {'status'=>'confirmed'}
end
owner = T::Dialogs::Owner.new(-> {actor}, ->(message) {raise message})
manager = T::ParticipantManager.new(program:program,workspace:workspace,owner:owner,publication:row,
  confirm:->(message) {confirmations << message; true},alert:->(message) {alerts << message},
  invite:->(*) {calls << :invite},clock:-> {150})
driver = TournamentControlCallbacks.new
driver.step('Participants') do |form|
  list=form.fields.first
  assert_equal(%w[Alpha Beta Gamma Delta],list.options)
  list.index=2
  list.trigger(:select)
  assert_equal([:user,'Gamma'],calls.last)
  assert_equal([:invite,:partner,:remove,:invitations,:refresh],manager.send(:available_actions).map(&:first))
  manager.send(:execute,:partner)
  manager.send(:execute,:invitations)
  manager.send(:execute,:remove)
  assert_equal(%w[Alpha Beta Delta],list.options)
  assert_equal('Delta',list.options[list.index], 'Removal lost the neighbouring selection')
  form.cancel_button.press
end
driver.step('Partner') do |form|
  assert_equal(['Alpha','Beta','Delta','Without a partner'],form.fields.first.options)
  form.fields.first.index=1
  form.fields.first.trigger(:select)
end
driver.step('Invited users') do |form|
  assert_equal(['PendingPerson — Pending','DeclinedPerson — Declined'],form.fields.first.options)
  form.cancel_button.press
end
manager.run
driver.finish
assert(calls.any? { |entry|entry.is_a?(Array) && entry[0..3]==[:pair,11,'gamma','beta'] },'Partner selection was not applied')
assert_equal([:remove,'gamma'],calls.last)
actor='Visitor'
guest = T::ParticipantManager.new(program:program,workspace:workspace,owner:T::Dialogs::Owner.new(-> {actor},->(*) {}),
  publication:row,confirm:->(*) {raise 'Guest confirmation'},alert:->(*) {},invite:->(*) {raise 'Guest invite'},clock:-> {150})
driver=TournamentControlCallbacks.new
driver.step('Participants') do |form|
  assert_equal([:refresh],guest.send(:available_actions).map(&:first),'Guest sees organizer writes')
  form.fields.first.trigger(:select)
  assert_equal([:user,'Alpha'],calls.last)
  form.cancel_button.press
end
guest.run
driver.finish
puts 'PASS native participant callbacks: user menu, organizer actions, partner picker, removal/focus, two read-only statuses and guest guards; no keyboard injection'
operations=T::OperationsScreen.new(program:program,load:-> {[]},reconcile:->(*) {},alert:->(*) {},mode_label:'Shared tournaments',actor:actor)
%w[invitation invite_declined].each do |kind|
  message=operations.send(:label,{'kind'=>kind,'status'=>'confirmed','values'=>{'tournament_id'=>11,'account'=>'Alpha'}})
  assert(message.include?('11') && message.include?('confirmed'),'New invitation operation cannot be displayed/reconciled')
end
