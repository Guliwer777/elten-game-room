# Real host keyboard/Form, GameScreen::Input and PongSurface. The room uses
# the native-contract broker, not a live account or physical audio output.
require_relative '../support/duck_challenge_native'
require_relative '../support/native_room_harness'
require_relative '../../games/axel_pong'
require_relative '../../lib/game_screen'

class PendingPongEffectsFixture
  attr_reader :h, :viewer, :layout, :screen, :wait, :driver, :commands

  def initialize(viewer)
    @viewer = viewer
    @driver = DuckChallengeNativeDriver.new
    $currentthread = Thread.current
    @h = NativeRoomHarness.new(game: GameRoomGames::AxelPong.new, users: %w[Alice Bob])
    h.start
    if viewer == 'Carol'
      h.add_client(viewer)
      assert(h.join(viewer), 'The spectator did not join the native room')
      h.as(viewer) { h.transports.fetch(viewer).set_observer(h.table, true, actor: viewer) }
    end
    h.as(viewer) do
      replay = h.replay(viewer)
      @layout = GameRoomLayout::Screen.new(view_spec: h.game.game_view_spec(replay, viewer),
        users_header: 'Players', user_items: %w[Alice Bob Carol], phase: :active,
        own_table: viewer == 'Alice')
      layout.session_id = h.session['__id']
      layout.begin_bindings
      layout.chat.set_text('Keep this unsent draft.')
      layout.chat.restore_selection(index: 4, check: 4)
      layout.focus_game(silent: true)
      $lastactivecontrols = [layout.form]
      layout.form.focus
      @screen = GameScreen.new(program: ProgramDouble.new(h.broker.endpoint(viewer)),
        repository: h.repositories.fetch(viewer), game: h.game, session: h.session,
        table: h.table, table_owner: 'Alice', layout: layout,
        room_snapshot_provider: -> { h.transports.fetch(viewer).room_snapshot(h.table) },
        synchronizer: nil, game_services: {transport: h.transports.fetch(viewer)})
      @wait = GameScreen::WaitState.new(replay: replay, session: h.session, actor: viewer,
        membership: h.transports.fetch(viewer).membership_token(h.table['__id']))
      screen.send(:bind_wait_shortcuts, wait, layout,
        -> { screen.send(:remember_layout_position, layout) })
      @commands = []
      layout.surface.on_pong_command = ->(command) { commands << command }
    end
  end

  def pending
    @pending = GameRoomUI::PendingOperation.new(layout: layout, table_id: h.table['__id'],
      session_id: h.session['__id'], token: EltenAPI::Tasks::CancellationToken.new,
      title: 'Sending an existing action', clock: -> { driver.now })
  end

  def press(key, modifiers: [])
    SpeechOutput.reset
    h.as(viewer) do
      # Separate physical taps by an idle frame; the host deliberately
      # suppresses a repeated key edge in adjacent input frames. Keep Ctrl
      # held through dispatch, as native FormBase passes the current modifiers.
      driver.snapshot([], [])
      events = modifiers.map { |modifier| [modifier, true] } +
        [[key, true, driver.raw([key] + modifiers)], [key, false]]
      driver.snapshot(events, modifiers)
      assert(layout.form.__send__(:keyevents).any? { |event| event.first == "key_#{key.chr.downcase}".to_sym },
        'Native driver did not deliver the requested shortcut')
      if layout.form.game_room_pending_operation
        layout.form.game_room_pending_operation.update
      else
        layout.form.update
      end
    end
    SpeechOutput.calls.map(&:first)
  end

  def close
    @pending&.close
    h.as('Alice') { h.view('Alice')&.close }
    $lastactivecontrols = $activecontrols = []
  end
end

cases = 0
%w[Alice Carol].each do |viewer|
  f = PendingPongEffectsFixture.new(viewer)
  begin
    surface = f.layout.surface
    assert(surface.instance_of?(GameSurfaces::PongSurface), 'Fixture bypassed the real Pong surface')
    assert((surface.spec.viewer == nil) == (viewer == 'Carol'), 'Fixture does not cover both player and spectator')
    original_history = Marshal.dump(f.h.core.entries)
    original_focus = f.layout.focus_location
    original_chat = [f.layout.chat.text, f.layout.chat.index, f.layout.chat.check]
    operation = f.pending
    [
      [{'shields' => [125, 0], 'invisible' => true}, 'Alice: shield, 2 seconds. The ball is invisible.'],
      [{'shields' => [0, 63], 'invisible' => false}, 'Bob: shield, 2 seconds.'],
      [{'shields' => [0, 0], 'invisible' => false}, 'No active effects.'],
      [nil, 'Waiting for the current snapshot.']
    ].each do |snapshot, expected|
      surface.present(snapshot, 'Waiting for the current snapshot.')
      before = Marshal.dump(snapshot)
      heard = f.press(0x45)
      assert(heard == [expected], "#{viewer}: pending E did not read current effects: #{heard.inspect}")
      assert(Marshal.dump(surface.snapshot) == before, 'Reading effects mutated the current snapshot')
      assert(f.layout.focus_location == original_focus, 'Reading effects moved native focus')
      assert([f.layout.chat.text, f.layout.chat.index, f.layout.chat.check] == original_chat,
        'Reading effects changed the unsent native chat draft/caret')
      assert(f.wait.action == nil && f.screen.instance_variable_get(:@selected_surface_action) == nil &&
        f.screen.instance_variable_get(:@pending_move_intent) == nil, 'Reading effects queued or submitted a move')
      assert(f.commands.empty? && Marshal.dump(f.h.core.entries) == original_history,
        'Reading effects sent a Pong command or changed the native game history')
      assert(operation.active?, 'Reading effects finished or replaced the existing operation')
      cases += 1
    end
    if viewer == 'Alice'
      heard = f.press(0x57, modifiers: [0x11])
      assert(heard == ['Please wait...'] && f.commands.empty?, 'Pending Ctrl+W bypassed the existing action guard')
      assert(f.wait.action == nil, 'Pending Ctrl+W resumed the form')
    end
    # The same genuine shortcut still works normally after task completion;
    # its previous refusal must not leave an action waiting to replay later.
    operation.close
    assert(f.commands.empty?, 'Finishing the operation replayed a refused command')
    surface.present({'shields' => [0, 0], 'invisible' => true}, 'Ready')
    assert(f.press(0x45) == ['The ball is invisible.'], 'Ordinary E stopped working after the pending operation')
    if viewer == 'Alice'
      f.press(0x57, modifiers: [0x11])
      assert(f.commands == ['hurry'], 'Ordinary Ctrl+W did not return through the original callback')
    end
    assert(Marshal.dump(f.h.core.entries) == original_history, 'Shortcut test unexpectedly wrote a durable game event')
  ensure
    f&.close
  end
end

puts "PASS native Pong effects: #{cases} pending reads, player/spectator, current/empty/missing snapshot, unchanged focus/draft/history and guarded Ctrl+W"
