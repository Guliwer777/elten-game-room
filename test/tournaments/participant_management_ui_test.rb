require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/ui'
require_relative '../support/tournament_public_ui'
require_relative '../../lib/tournaments/public_preview'
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
T = TournamentPublicUI
Form.prepend(T::Script)
snapshot = T.snapshot([T.publication], [T.registration(1)])
calls = []
preview=nil
T.script(lambda do |form|
  actions=form.fields.first
  assert(actions.is_a?(ListBox), 'Tournament actions must be the first control')
  actions.index=actions.options.index('Leave tournament')
  assert(actions.index,'Withdrawal action missing before start')
  actions.trigger(:select)
  preview.send(:request_withdrawal)
  assert(calls == [11], 'Withdrawal must be sent at most once per preview')
  assert(!actions.options.include?('Leave tournament'),'Withdrawal remains visible after leaving')
  assert(T.field(form, 'Status').text.include?('Withdrawal confirmed.'), 'Missing withdrawal confirmation')
  form.cancel_button.trigger(:press)
end) do
  preview=GameRoomTournaments::PublicPreview.new(**T.arguments(snapshot, load: -> { T.snapshot }, alert: ->(*) {}),
    clock:-> {150},withdraw: ->(id) { calls << id; T.record('confirmed') })
  preview.wait
end
[T::ACTOR, 'Organizator Łukasz'].each do |actor|
  T.script(lambda do |form|
    actions=form.fields.first.options
    assert(actions.include?('Manage tournament') == (actor == 'Organizator Łukasz'), 'Management visible to a non-organizer')
    form.cancel_button.trigger(:press)
  end) do
    GameRoomTournaments::PublicPreview.new(**T.arguments(T.snapshot, load: -> { T.snapshot }, alert: ->(*) {}).merge(actor: actor),
      clock:-> {150},manage_participants: ->(*) { raise 'Unrequested management action' }, edit_tournament: ->(*) {}, delete_tournament: ->(*) {}).wait
  end
end
puts 'PASS withdrawal confirmation, duplicate guard and organizer-only management controls'
