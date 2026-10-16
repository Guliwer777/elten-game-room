require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/ui'
require_relative '../support/tournament_local_hub'
class Static < FakeControl
  attr_reader :text
  def initialize(text); super(); @text = text; end
  def focus(*); end
end
class EditBox
  module Flags
    Numbers = 8 unless const_defined?(:Numbers)
  end
  def select_all; @index, @check = 0, text.length; end
end
require_relative '../../lib/tournaments/server_trial_hub'
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
T = TournamentLocalHubTest
Form.prepend(T::Script)
program = Object.new
program.define_singleton_method(:data_path) { raise 'Unexpected I/O on entering server menu' }
args = T.args(program: program)
T.script(->(form) {
  assert(form.fields.first.text.include?('Current identity: RealOwner'), 'Account not shown')
  labels = form.fields.grep(Button).map(&:label)
  assert(labels == ['Tournament list', 'Create and publish tournament', 'Operations', 'Back'], labels.inspect)
  assert(form.fields.first.text.include?('Automatic invitations are not available yet.'), 'Remote trial limitation missing')
  form.cancel_button.trigger(:press)
}) { GameRoomTournaments::ServerTrialHub.new(**args).run }
puts 'PASS server menu: explicit backend, current account, no I/O on entry, no virtual actors or execution tools'

T.script(->(form) {
  T.button(form, 'Create and publish tournament').trigger(:press)
  form.cancel_button.trigger(:press)
}, ->(form) {
  assert(form.fields.first.header == 'Game')
  form.fields.first.index = GameRoomGames::CATALOG.ids.index('tic_tac_toe')
  form.fields.first.trigger(:select)
}, ->(form) {
  assert(form.fields.grep(Button).map(&:label) == ['Next', 'Cancel'])
  form.accept_button.trigger(:press)
}, ->(form) {
  T.button(form, 'Publish in server test')
  form.cancel_button.trigger(:press)
}) { GameRoomTournaments::ServerTrialHub.new(**args).run }
puts 'PASS server creation button identifies the remote test backend and cancellation performs no I/O'
