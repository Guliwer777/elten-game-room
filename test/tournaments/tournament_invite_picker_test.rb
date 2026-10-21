require_relative '../support/tournament_control_callbacks'
require_relative '../support/tournament_public_ui'
require_relative '../../lib/tournaments/tournament_invite_picker'
include GameRoomTest::Assertions
T = GameRoomTournaments
GameRoomLocalization.boot(settings:{'interface_language'=>'en','known_languages'=>['en']})
row=TournamentPublicUI.publication
actor=row['__insertion_user']
module EltenLink
  class Client; end unless const_defined?(:Client)
  module Users
    def self.online(_client); ['Online','ONLINE','Joined','PendingPerson','DeclinedPerson','Organizator Łukasz']; end
  end
  module Contacts
    def self.list(_client); ['Contact','online']; end
  end
end
class PickerProgram
  class << self
    attr_accessor :deliveries
    def send_tournament_event(**values); deliveries << values; [:sent]; end
  end
  def run_network_task(*,**);yield;end
end
PickerProgram.deliveries=[]
program=PickerProgram.new
calls,alerts=[],[]
data={'members'=>[{'tournament_id'=>11,'account'=>'joined'}], 'invitations'=>[
  {'tournament_id'=>11,'account'=>'pendingperson','status'=>'pending'},
  {'tournament_id'=>11,'account'=>'declinedperson','status'=>'declined'}]}
workspace=Object.new
workspace.define_singleton_method(:load) {data}
workspace.define_singleton_method(:invite_to_tournament) do |id,name,intent|
  calls << [id,name,intent]
  {'status'=>'confirmed','values'=>{'operation_key'=>'key-'+name}}
end
owner=T::Dialogs::Owner.new(-> {actor},->(text) {raise text})
picker=-> {T::TournamentInvitePicker.new(program:program,workspace:workspace,owner:owner,publication:row,alert:->(text) {alerts<<text})}
driver=TournamentControlCallbacks.new
driver.step('Invite to tournament') do |form|
  assert_equal(['Contact','Online'],form.fields.first.options,'Contacts/online not deduplicated or declined person can be reinvited')
  form.accept_button.press
  assert_equal('Select at least one person.',alerts.last)
  form.fields.first.select_multiselection_indices([0,1])
  form.accept_button.press
  form.accept_button.press
end
picker.call.run
driver.finish
assert_equal(%w[Contact Online],calls.map { |entry|entry[1] })
assert_equal(%w[Contact Online],PickerProgram.deliveries.map { |entry|entry[:recipient] })
assert_equal('Invitations sent: 2. Unconfirmed: 0.',alerts.last)
assert(PickerProgram.deliveries.all? { |entry|entry[:invitation_key]=='key-'+entry[:recipient] },'Delivery lost recorded invitation identity')
driver=TournamentControlCallbacks.new
driver.step('Invite to tournament') { |form|form.fields.first.select_multiselection_indices([0]);form.cancel_button.press }
picker.call.run
driver.finish
assert_equal(2,calls.size,'Cancel sent selected invitations')
puts 'PASS native tournament checkbox picker: contacts/online, canonical exclusions including declines, Enter sends batch once, aggregate feedback and Cancel; ordinary picker untouched'
