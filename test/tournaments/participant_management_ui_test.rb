require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/ui'
require_relative '../support/tournament_public_ui'
require_relative '../../lib/tournaments/public_preview'
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
T = TournamentPublicUI
Form.prepend(T::Script)
snapshot = T.snapshot([T.publication], [T.registration(1)])
calls = []
T.script(lambda do |form|
  T.button(form, 'Leave tournament').trigger(:press)
  T.button(form, 'Leave tournament').trigger(:press)
  assert(calls == [11], 'Withdrawal must be sent at most once per preview')
  assert(T.field(form, 'Status').text.include?('Withdrawal confirmed.'), 'Missing withdrawal confirmation')
  form.cancel_button.trigger(:press)
end) do
  GameRoomTournaments::PublicPreview.new(**T.arguments(snapshot, load: -> { T.snapshot }, alert: ->(*) {}),
    withdraw: ->(id) { calls << id; T.record('confirmed') }).wait
end
[T::ACTOR, 'Organizator Łukasz'].each do |actor|
  T.script(lambda do |form|
    buttons = form.fields.grep(Button).map(&:label)
    assert(buttons.include?('Manage participants') == (actor == 'Organizator Łukasz'), 'Participant management visible to a non-organizer')
    assert(buttons.include?('Edit tournament') == (actor == 'Organizator Łukasz'), 'Edit shown to non-author')
    assert(buttons.include?('Delete tournament') == (actor == 'Organizator Łukasz'), 'Delete shown to non-author')
    form.cancel_button.trigger(:press)
  end) do
    GameRoomTournaments::PublicPreview.new(**T.arguments(T.snapshot, load: -> { T.snapshot }, alert: ->(*) {}).merge(actor: actor),
      manage_participants: ->(*) { raise 'Unrequested management action' }, edit_tournament: ->(*) {}, delete_tournament: ->(*) {}).wait
  end
end
puts 'PASS withdrawal confirmation, duplicate guard and organizer-only management controls'
