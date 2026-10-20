require_relative '../../support/native_room_harness'
require_relative '../../../games/mahjong'
require_relative '../../../lib/game_event_presenter'

ProgramDouble.define_singleton_method(:normalized_settings) { {'background_turn_sound'=>true} }
original_play = GameRoomSounds.method(:play)
sounds = []
GameRoomSounds.define_singleton_method(:play) { |_program, cue| sounds << cue; nil }
begin
  [['solitaire', 1], ['hong_kong', 4], ['riichi', 4], ['riichi', 3], ['mcr', 4]].each do |variant, seats|
    game = GameRoomGames::Mahjong.new
    options = game.normalize_options('variant'=>variant, 'riichi_seats'=>seats.to_s)
    h = NativeRoomHarness.new(game: game, users: %w[Alice Bob Carol Dave].first(seats), options: options)
    h.start
    begin
      replay = h.replay('Alice')
      before = sounds.length
      presenter = GameRoomEventPresenter.new(game: -> { game }, repository: -> { h.repositories['Alice'] },
        program: -> { ProgramDouble.new(h.broker.endpoint('Alice')) }, viewer: -> { 'Alice' }, client: -> { nil },
        surface_state: -> { nil }, clock: -> { nil }, covered: -> { true }, speech: ->(*) {}, trace: ->(*) {},
        history_changed: ->(*) {}, session_changed: -> {})
      # The first real presenter callback compares this key with a nil prior
      # replay. Opening the table must neither crash nor emit duplicate cues.
      presenter.process_new_events(replay, session: h.session)
      presenter.process_new_events(replay, session: h.session)
      assert(sounds.length == before + 1, 'initial Mahjong decision cue was missing or duplicated')
      assert(game.required_decision_key(nil, 'Alice').nil?, 'nil prior replay must have no decision key')
    ensure
      h.as('Alice') { h.transports['Alice'].deactivate_table(table_id: h.table['__id']) }
    end
  end
ensure
  GameRoomSounds.define_singleton_method(:play, original_play)
end
puts 'PASS initial Mahjong presentation: actual first-event callback, nil prior replay, all variants/seats and one decision cue'
