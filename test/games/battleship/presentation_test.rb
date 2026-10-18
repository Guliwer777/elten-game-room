binary_screen_run = nil
if ARGV.first || ENV["BATTLESHIP_BINARY_SOURCE"] == "1"
  require_relative "../../support/binary_rules_load"
  binary_screen_run = GameScreen.instance_method(:run)
else
  require_relative "../../support/ui"
  require_relative "../../../lib/game_surfaces"
  require_relative "../../../lib/game_screen"
  require_relative "../../../games/battleship"
end
require_relative "../../support/native_room_harness"
require_relative "../../support/log"
raise "Binary screen was replaced by filesystem code" if binary_screen_run && GameScreen.instance_method(:run) != binary_screen_run

require_relative "../../support/battleship_presentation"

h = NativeRoomHarness.new(game: GameRoomGames::Battleship.new, users: %w[Alice Bob])
h.start
vault = HiddenSubmissions::Vault.new(HiddenSubmissions::MemoryStorage.new)
context = GameRoomGames::ActionContext.new(session_id: h.session["__id"], hidden_submissions: vault)
sample = [[0,1,2,3],[20,21,22],[40,41,42],[60,61],[80,81],[85,86],[8],[28],[48],[68]]
h.submit("Alice", { "action" => "begin" }, context: context)
%w[Alice Bob].each { |actor| h.submit(actor, { "action" => "seal", "ships" => JSON.generate(sample) }, context: context) }
sync = GameRoomSync::Controller.new(transport: h.transports["Alice"], table_id: h.table["__id"], session_id: h.session["__id"])
10.times { sync.next_event }
clips = []
program = ProgramDouble.new(h.broker.endpoint("Alice"))
program.define_singleton_method(:game_room_sound_volume) { |_name| 1.0 }
program.define_singleton_method(:play_sound_from_asset) { |name, volume:| clips << BattleshipClip.new(name, volume: volume); clips.last }
sent = []
screen = GameScreen.new(program: program, repository: h.repositories["Alice"], game: h.game,
  session: h.session, table: h.table, table_owner: "Alice", synchronizer: sync,
  room_snapshot_provider: -> { LobbyRepository::TableSnapshot.new(**h.transports["Alice"].room_snapshot(h.table)) },
  send_chat: ->(_table, message, _members, **_options) { sent << message; nil })
screen.instance_variable_set(:@hidden_submissions, vault)
screen.define_singleton_method(:alert) { |message| raise "unexpected alert: #{message}" }
stage = 0
reads = nil
shared_controls = nil
Form.driver = lambda do |form|
  stage += 1
  raise "presentation did not progress" if stage > 8
  layout = screen.instance_variable_get(:@layout)
  queue = screen.send(:event_presenter).instance_variable_get(:@event_presentation)
  fire = -> { form.instance_variable_get(:@timers).each(&:fire) }
  case stage
  when 1
    assert(clips.empty?, "old fleet seals were played on entry")
    shared_controls = [layout.chat, layout.users, layout.history]
    layout.chat.text = "draft ąę"
    layout.chat.index, layout.chat.check = 7, 2
    h.submit("Alice", { "action" => "select", "x" => 0, "y" => 0 }, context: context)
    h.submit("Bob", { "action" => "answer" }, context: context)
    fire.call
  when 2
    assert(clips.length == 1 && GameRoomSounds::BATTLESHIP_LAUNCHES.include?(clips.last.name), "batched answer overtook launch")
    assert(queue.visible_replay.state[:phase] == :answering, "future answer leaked into board")
    assert(!layout.history.text.include?("A1: hit"), "future hit leaked into history")
    assert([layout.chat.text, layout.chat.index, layout.chat.check] == ["draft ąę", 7, 2], "queued shot lost chat characters/selection")
    layout.surface.fields.first.trigger(:select, [1,0])
    assert(screen.instance_variable_get(:@selected_surface_action) == nil, "input during playback submitted another shot")
    current = h.replay("Alice")
    assert(!screen.send(:perform_automatic_action, current), "automatic action bypassed sound pause")
    # Bot pacing uses the shared worker's published busy view; the real
    # worker boundary is exercised by game_session_runner_test.
    # Another client can advance the authoritative game while this one's audio
    # is slower. The received event must be queued, not ignored or shown early.
    h.submit("Bob", { "action" => "select", "x" => 9, "y" => 9 }, context: context)
    fire.call
  when 3
    assert(queue.visible_replay.state[:pending]["shooter"] == "Alice" && clips.length == 1, "later network event jumped audio queue")
    assert(screen.send(:event_presenter).instance_variable_get(:@last_seen_event_id) == h.repositories["Alice"].event_id(h.events("Alice").last), "network consumption stopped during audio")
    assert(shared_controls == [layout.chat, layout.users, layout.history], "network refresh replaced shared controls")
    layout.chat.trigger(:select)
  when 4
    assert(sent == ["draft ąę"] && clips.length == 1, "chat was blocked or repeated a sound")
    clips.first.done = true
    reads = h.view("Alice").calls[:read]
    fire.call
  when 5
    assert(h.view("Alice").calls[:read] == reads, "sound completion polled the server")
    assert(clips.length == 2 && GameRoomSounds::BATTLESHIP_HITS.include?(clips.last.name), "hit did not follow completed launch")
    assert(queue.visible_replay.state[:shots]["Alice"][0] == "hit", "hit board did not appear")
    clips.last.done = true
    fire.call
  when 6
    assert(clips.length == 3 && GameRoomSounds::BATTLESHIP_LAUNCHES.include?(clips.last.name), "queued enemy launch lost")
    assert(queue.visible_replay.state[:pending]["shooter"] == "Bob", "wrong pending shot")
    assert(h.replay("Alice").state[:phase] == :answering, "answer was sent while launch still plays")
    clips.last.done = true
    fire.call
  when 7
    assert(clips.length == 4 && clips.last.name == "rocket_miss", "automatic reply did not resume after launch")
    assert(h.replay("Alice").current_player == "Alice", "automatic answer did not advance real state")
    clips.last.done = true
    fire.call
  when 8
    assert(!queue.busy?, "final sound left game locked")
    assert(clips.length == 4, "duplicate playback after refresh")
    assert(shared_controls == [layout.chat, layout.users, layout.history], "presentation refresh replaced chat")
    layout.back_button.trigger(:press)
  end
end
h.as("Alice") { assert(screen.run == :back && stage == 8, "interactive presentation failed") }
assert(clips.all? { |clip| clip.volume == 0.2 && clip.length == 4.0 }, "quieter effects changed the sound duration or lost their gain")
assert(!screen.send(:event_presentation_busy?), "leaving kept audio queue alive")
h.assert_converged("after serial playback")
puts "PASS Battleship native-transport/form simulation: ordered sounds/views, live sync and chat, no extra polls, action guards, automatic reply and deduplication"

# Test the real screen boundary as well as the FleetGrid in isolation: selecting
# manual setup must rebuild locally, not submit a pseudo-move to the server.
def confirm(_message); true; end
%w[manual random].each do |mode|
  setup_h = NativeRoomHarness.new(game: GameRoomGames::Battleship.new, users: %w[Alice Bob])
  setup_h.start
  setup_vault = HiddenSubmissions::Vault.new(HiddenSubmissions::MemoryStorage.new)
  setup_context = GameRoomGames::ActionContext.new(session_id: setup_h.session["__id"], hidden_submissions: setup_vault)
  setup_h.submit("Alice", { "action" => "begin" }, context: setup_context)
  setup_h.submit("Bob", { "action" => "seal", "ships" => JSON.generate(sample) }, context: setup_context)
  setup_sync = GameRoomSync::Controller.new(transport: setup_h.transports["Alice"], table_id: setup_h.table["__id"], session_id: setup_h.session["__id"])
  10.times { setup_sync.next_event }
  setup_screen = GameScreen.new(program: ProgramDouble.new(setup_h.broker.endpoint("Alice")),
    repository: setup_h.repositories["Alice"], game: setup_h.game, session: setup_h.session,
    table: setup_h.table, table_owner: "Alice", synchronizer: setup_sync,
    room_snapshot_provider: -> { LobbyRepository::TableSnapshot.new(**setup_h.transports["Alice"].room_snapshot(setup_h.table)) })
  setup_screen.instance_variable_set(:@hidden_submissions, setup_vault)
  setup_screen.define_singleton_method(:alert) { |message| raise "setup alert: #{message}" }
  count, setup_reads = 0, nil
  Form.driver = lambda do |_form|
    count += 1
    layout = setup_screen.instance_variable_get(:@layout)
    if count == 1
      assert(layout.surface.fields.first.is_a?(ListBox), "screen skipped random/manual choice")
      layout.surface.fields.first.index = mode == "manual" ? 1 : 0
      setup_reads = setup_h.view("Alice").calls[:read]
      layout.surface.fields.first.trigger(:select)
    elsif count == 2 && mode == "manual"
      assert(setup_h.view("Alice").calls[:read] == setup_reads, "manual selection sent a network read")
      assert(setup_h.events("Alice").length == 2, "manual choice wrote a game event")
      assert(layout.surface.fields.first.is_a?(GridBox), "manual choice did not focus the board")
      sample.each do |ship|
        layout.surface.fields.first.trigger(:select, [ship.first % 10, ship.first / 10])
        layout.surface.fields.first.trigger(:select, [ship.last % 10, ship.last / 10])
      end
    else
      assert(count == (mode == "manual" ? 3 : 2), "setup choice repeated")
      sealed = setup_h.replay("Alice")
      assert(sealed.state[:phase] == :playing && sealed.accepted_events.length == 3, "setup failed to seal exactly once")
      assert(layout.surface.is_a?(GameSurfaces::CompositeSurface), "setup board remained after sealing")
      layout.back_button.trigger(:press)
    end
  end
  setup_h.as("Alice") { assert(setup_screen.run == :back, "#{mode} setup screen failed") }
end
puts "PASS Battleship real-screen setup: random seals once, manual opens locally, full placement reaches play without repeating the question"
