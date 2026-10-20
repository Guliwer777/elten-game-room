# encoding: UTF-8
require_relative '../support/binary_rules_load'
require_relative '../support/tournament_public_ui'
require_relative '../../lib/tournaments/tournament_setup_editor'

# Exercise the current publication editor. The retired local DraftWorkspace is
# deliberately not a runtime asset and must not be loaded from the checkout.
Form.prepend(TournamentPublicUI::Script)
ui = TournamentPublicUI
registry = EltenGameRoom::GAME_REGISTRY
label = GameRoomContent.utf8(GameRoomLocalization.translate('Tournaments'))
assert(EltenGameRoom::MAIN_OPTIONS.map { |value| GameRoomContent.utf8(value) }.include?(label), 'Missing tournament lobby entry')
assert(defined?(GameRoomTournaments::ServerWorkspace), 'Missing server workspace')
%w[en pl].each do |language|
  GameRoomTestLocalization.use_language(language)
  tr = ->(value) { GameRoomContent.utf8(GameRoomLocalization.translate(value)) }
  %w[three_five_eight tic_tac_toe mahjong].each do |game_id|
    published = []
    configured = []
    notes = "Żółw — próba.\nAsk the organizer before the final."
    editor = GameRoomTournaments::TournamentSetupEditor.new(
      program: Object.new, registry: registry, clock: -> { 1000 },
      configure: ->(game, values) {
        values = values.merge('variant' => 'hong_kong') if game.id == 'mahjong'
        options = game.normalize_options(values)
        configured << [game.id, Marshal.load(Marshal.dump(options))]
        options
      }, alert: ->(message) { raise message },
      publish_label: tr.call('Publish tournament'),
      publish: ->(**values) { published << values; {'status' => 'confirmed'} })
    ui.script(->(form) {
      list = ui.field(form, tr.call('Game'))
      assert(list.options.size == registry.ids.size, 'Game chooser omitted a registered game')
      list.index = registry.ids.index(game_id)
      list.trigger(:select)
    }, ->(form) {
      form.fields.each do |control|
        values = []
        values << control.header if control.respond_to?(:header) && control.header
        values << control.label if control.respond_to?(:label)
        values << control.text if control.respond_to?(:text)
        values.concat(control.options) if control.respond_to?(:options)
        invalid = values.reject do |value|
          value.is_a?(String) && value.valid_encoding? && (value.encoding == Encoding::UTF_8 || value.ascii_only?)
        end
        assert(invalid.empty?, "Invalid packaged form text in #{language}/#{game_id}: #{invalid.inspect}")
      end
      ui.field(form, tr.call('Tournament name')).set_text('Jesienny — Łódź')
      ui.field(form, tr.call("Organizer's notes (optional)")).set_text(notes)
      ui.button(form, tr.call('Back')).trigger(:press)
      assert(published.empty?, 'Back published a tournament')
      assert(configured.size == 2 && configured.first == configured.last, 'Back lost configured game options')
      assert(ui.field(form, tr.call('Tournament name')).text == 'Jesienny — Łódź', 'Back lost the name')
      assert(ui.field(form, tr.call("Organizer's notes (optional)")).text == notes, 'Back lost notes')
      form.accept_button.trigger(:press)
    }) { editor.wait }
    assert(published.one?, 'Publication was lost or duplicated')
    draft = published.first.fetch(:draft)
    assert(draft.fetch('game_id') == game_id && draft.fetch('game_options') == configured.last.last,
      'Publication changed selected game options')
    assert(published.first.fetch(:rules) == notes, 'Publication rewrote organizer notes')
  end
end
puts 'PASS packaged tournament editor: current server entry, localized native forms, game choice, Back, options and author notes'
