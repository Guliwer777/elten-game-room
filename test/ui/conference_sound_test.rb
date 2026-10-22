require_relative '../support/table_watch_runtime'
require_relative '../support/assertions'
include GameRoomTest::Assertions
require_relative '../../lib/game_event_presenter'
played = []
program = Object.new
program.define_singleton_method(:play_sound_from_asset) { |asset, **options| played << [asset, options]; :voice }
program.define_singleton_method(:game_room_sound_volume) { |_| 0.35 }
enabled = true
program.define_singleton_method(:game_room_sound_enabled?) { |_| enabled }
entry = Struct.new(:id, :kind, :actor).new(1, 'voice_started', 'Alice')
build = -> { GameRoomEventPresenter.new(game:nil, repository:nil, program:-> {program}, viewer:nil,
  client:nil, surface_state:nil, clock:nil, covered:nil, speech:->(*) {}, trace:nil,
  history_changed:nil, session_changed:nil) }
presenter = build.call
presenter.process_table_activity([], viewer:'Bob', text:->(*) {''})
2.times { presenter.process_table_activity([entry], viewer:'Bob', text:->(*) {''}) }
assert_equal([['conference_created', {volume:0.35}]], played)
late = build.call
late.process_table_activity([entry], viewer:'Bob', text:->(*) {''})
assert_equal(1, played.size, 'Reconstruction replayed the conference cue')
enabled = false
presenter.process_table_activity([entry,entry.dup.tap { |e|e.id=2 }], viewer:'Bob', text:->(*) {''})
assert_equal(1, played.size, 'Muted conference played')
assert_equal('room', GameRoomPreferences.sound_group('conference_created'))
manifest = JSON.parse(File.read(File.expand_path('../../manifest.json', __dir__)))
assert(manifest.dig('required_assets','sounds').include?('conference_created'), 'Undeclared conference cue')
assert(File.binread(File.expand_path('../../Audio/conference_created.opus', __dir__),64).include?('OpusHead'), 'Invalid Opus')
puts 'PASS conference cue: new activity once, no reconstruction/duplicate, shared room volume and packaged Opus'
