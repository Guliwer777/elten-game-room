require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/ui'
require_relative '../support/tournament_local_hub'
require_relative '../../lib/tournaments/hub'
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
T = TournamentLocalHubTest
Form.prepend(T::Script)
program = Object.new
program.define_singleton_method(:data_path) { raise 'Unexpected I/O on entering server menu' }
args = T.args(program: program)
T.script(->(form) {
  T.button(form, "Server test — guliwer's separate application").trigger(:press)
  form.cancel_button.trigger(:press)
}, ->(form) {
  assert(form.fields.first.text.include?('Current identity: RealOwner'), 'Account not shown')
  labels = form.fields.grep(Button).map(&:label)
  assert(labels == ['Tournament list', 'Create and publish tournament', 'Operations', 'Back'], labels.inspect)
  assert(form.fields.first.text.include?('not shared yet'), 'Remote execution limitation missing')
  form.cancel_button.trigger(:press)
}) { GameRoomTournaments::Hub.new(**args).run }
puts 'PASS server menu: explicit backend, current account, no I/O on entry, no virtual actors or execution tools'

T.script(->(form) {
  T.button(form, 'Create and publish tournament').trigger(:press)
  form.cancel_button.trigger(:press)
}, ->(form) {
  T.button(form, 'Publish in server test')
  form.cancel_button.trigger(:press)
}) { GameRoomTournaments::ServerTrialHub.new(**args).run }
puts 'PASS server creation button identifies the remote test backend and cancellation performs no I/O'
