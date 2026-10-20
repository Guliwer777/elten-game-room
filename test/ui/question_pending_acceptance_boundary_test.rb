require_relative '../support/duck_challenge_native'
require_relative '../support/krowa'
require_relative '../support/session_runner'
require_relative '../../lib/game_screen'

class PendingNativeQuestionFixture
  attr_reader :h, :runner, :screen, :layout, :wait, :driver

  def initialize
    @driver = DuckChallengeNativeDriver.new
    $currentthread = Thread.current
    $game_room_test_user = 'Alice'
    game = KrowaTestGame.new.game
    @h = NativeRoomHarness.new(game: game, users: ['Alice'],
      options: game.default_options.merge('variant' => 'random', 'length' => 3))
    h.start
    @runner = runner_for(h)
    step(h, runner, count: 2)
    replay = h.replay('Alice')
    assert(replay.state[:phase] == :active, 'Question fixture did not start')
    @layout = GameRoomLayout::Screen.new(view_spec: game.game_view_spec(replay, 'Alice'),
      users_header: 'Players', user_items: ['Alice'], phase: :active, own_table: true)
    layout.session_id = h.session['__id']
    layout.begin_bindings
    layout.focus_game(silent: true)
    $lastactivecontrols = [layout.form]
    layout.form.focus
    @screen = GameScreen.allocate
    {game: game, table: h.table, session: h.session, table_owner: 'Alice',
      repository: h.repositories['Alice'], session_runner: runner, layout: layout,
      game_services: {transport: h.transports['Alice']}}.each do |name, value|
      screen.instance_variable_set("@#{name}", value)
    end
    screen.define_singleton_method(:event_presentation_busy?) { false }
    screen.define_singleton_method(:alert) { |_message| }
    @wait = GameScreen::WaitState.new(replay: replay, session: h.session, actor: 'Alice',
      membership: h.transports['Alice'].membership_token(h.table['__id']))
    screen.send(:bind_wait_surface, wait, layout, -> { screen.send(:remember_layout_position, layout) })
  end

  def field; layout.surface.fields.first; end

  def type(text)
    field.set_text('')
    field.restore_selection(index: 0, check: 0)
    driver.frame(layout.form, text.chars.flat_map { |char| driver.tap(char.upcase.ord) }, characters: text)
    assert(field.text == text, 'Native edit did not receive all characters')
  end

  def pending
    GameRoomUI::PendingOperation.new(layout: layout, table_id: h.table['__id'],
      session_id: h.session['__id'], title: 'Independent table read',
      token: EltenAPI::Tasks::CancellationToken.new,
      move_admission: -> { screen.send(:move_admission_available?) })
  end

  def enter; driver.frame(layout.form, driver.tap(13)); end

  def drain
    h.as('Alice') { screen.send(:submit_pending_move) }
  end

  def reconstructed_text
    GameRoomLayout::Screen.new(view_spec: h.game.game_view_spec(h.replay('Alice'), 'Alice'),
      surface_state: screen.instance_variable_get(:@surface_state),
      users_header: 'Players', user_items: ['Alice'], phase: :active, own_table: true).surface.fields.first.text
  end

  def close
    layout.form.game_room_pending_operation&.close
    runner.close
    h.as('Alice') { h.view('Alice')&.close }
    $lastactivecontrols = $activecontrols = []
  end
end

def Log.warning(_message); end

[:unchanged, :new_draft, :retyped_same, :new_native_control, :stale, :invalid, :wrong_length, :invalid_new_draft, :invalid_retyped_same].each do |boundary|
  f = PendingNativeQuestionFixture.new
  begin
    initial = boundary.to_s.start_with?('invalid') ? 'xyz' : boundary == :wrong_length ? 'la' : 'las'
    f.type(initial)
    before = f.h.events('Alice').length
    operation = f.pending
    f.enter
    intent = f.screen.instance_variable_get(:@pending_move_intent)
    assert(intent && intent.selection['answer'] == initial, "#{boundary}: native pending Enter was dropped")
    assert(f.field.text == initial, "#{boundary}: queuing erased an unconfirmed answer")
    assert(intent.selection['_text_input'].all? { |item| item.is_a?(Integer) }, 'Queue retained native control objects')
    f.enter
    assert(f.screen.instance_variable_get(:@pending_move_intent).equal?(intent), 'Repeated Enter replaced the first intent')
    expected = initial
    if [:new_draft, :invalid_new_draft].include?(boundary)
      expected = 'dom'
      f.type(expected)
    elsif [:retyped_same, :invalid_retyped_same].include?(boundary)
      f.type(initial)
    elsif boundary == :stale
      f.h.as('Alice') { f.h.transports['Alice'].freeze_game(f.h.session) }
    end
    # This is the normal network task's before_close snapshot. It must retain
    # later edits even if the eventual acceptance belongs to an older draft.
    f.screen.send(:remember_layout_position, f.layout)
    operation.close
    if boundary == :new_native_control
      f.layout.update(view_spec: f.h.game.game_view_spec(f.h.replay('Alice'), 'Alice'),
        history_items: [], user_items: ['Alice'], users_header: 'Players',
        phase: :active, own_table: true, surface_state: f.layout.surface.state,
        reset_surface: true)
      assert(f.field.object_id != intent.selection['_text_input'][0], 'Fixture did not rebuild the native input')
    end
    accepted = f.drain
    if [:stale, :invalid, :wrong_length, :invalid_new_draft, :invalid_retyped_same].include?(boundary)
      expected = '' if [:invalid, :wrong_length].include?(boundary)
      assert(!accepted && f.field.text == expected, "#{boundary}: rejection cleared the wrong draft")
      assert(f.h.events('Alice').length == before, "#{boundary}: rejected pending answer entered game history")
      assert(f.reconstructed_text == expected, "#{boundary}: history restored the wrong rejected draft")
    else
      assert(accepted, "#{boundary}: valid captured answer did not pass the real runner")
      expected = '' if boundary == :unchanged
      assert(f.field.text == expected, "#{boundary}: acknowledgement cleared the wrong native draft")
      assert(f.reconstructed_text == expected, "#{boundary}: reconstructed view restored the wrong draft")
      delta = f.h.events('Alice').drop(before)
      assert(delta.length == 1 && delta.first['action'] == 'krowa_guess' &&
        delta.first['value'].split('|')[2] == initial, 'Accepted immutable answer changed or was duplicated')
      assert(!JSON.generate(f.h.core.entries).include?('_text_input'), 'Local input receipt leaked into a raw native packet')
      f.screen.send(:confirm_surface_action, f.layout.surface, intent.selection,
        session_id: f.h.session['__id'])
      assert(f.field.text == expected, 'Duplicate callback cleared a different draft')
    end
    assert(f.screen.instance_variable_get(:@pending_move_intent).nil?, 'Pending answer remained queued after drain')
  ensure
    f&.close
  end
end

puts 'PASS native question queue: acceptance, declared Krowa validation clearing, preserved stale/new/ABA drafts, history reconstruction and no raw packet metadata'
