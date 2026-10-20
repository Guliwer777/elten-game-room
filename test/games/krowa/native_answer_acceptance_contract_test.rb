require_relative '../../support/duck_challenge_native'
require_relative '../../support/krowa'
require_relative '../../support/session_runner'
require_relative '../../../lib/game_screen'

class KrowaNativeAnswerAcceptance
  attr_reader :driver, :native, :runner, :screen, :layout, :wait, :alerts

  def initialize
    @driver = DuckChallengeNativeDriver.new
    $currentthread = Thread.current
    $game_room_test_user = 'Alice'
    game = KrowaTestGame.new.game
    @native = NativeRoomHarness.new(game: game, users: ['Alice'],
      options: game.default_options.merge('variant' => 'random', 'length' => 3))
    native.start
    @runner = runner_for(native)
    step(native, runner, count: 2)
    @replay = native.replay('Alice')
    assert(@replay.state[:phase] == :active, 'Krowa setup did not produce a word')
    @layout = GameRoomLayout::Screen.new(view_spec: game.game_view_spec(@replay, 'Alice'),
      history_items: [], user_items: ['Alice'], users_header: 'Users', phase: :active, own_table: true)
    layout.session_id = native.session['__id']
    layout.begin_bindings
    layout.focus_game(silent: true)
    $lastactivecontrols = [layout.form]
    layout.form.focus
    @alerts = []
    @screen = GameScreen.allocate
    {game: game, table: native.table, session: native.session, table_owner: 'Alice',
      repository: native.repositories['Alice'], session_runner: runner, layout: layout}.each do |name, value|
      screen.instance_variable_set("@#{name}", value)
    end
    screen.define_singleton_method(:event_presentation_busy?) { false }
    screen.define_singleton_method(:alert) { |message| @acceptance_alerts << message }
    screen.instance_variable_set(:@acceptance_alerts, alerts)
    # Keep the real task/runner/acknowledgement boundary. Only suppress logging
    # in the headless host, whose tutorial fixture otherwise raises warnings.
    @wait = GameScreen::WaitState.new(replay: @replay, session: native.session, actor: 'Alice')
    screen.send(:bind_wait_surface, wait, layout, -> { screen.send(:remember_layout_position, layout) })
  end

  def field; layout.surface.fields.first; end
  def selection; screen.instance_variable_get(:@selected_surface_action); end
  def type(value)
    driver.frame(layout.form, value.chars.flat_map { |char| driver.tap(char.upcase.ord) }, characters: value)
    assert(field.text == value, 'Native edit did not receive the answer')
  end
  def enter; driver.frame(layout.form, driver.tap(13)); end
  def submit; native.as('Alice') { screen.send(:submit_action, @replay) }; end
  def close
    runner.close
    native.as('Alice') { native.view('Alice')&.close }
    $lastactivecontrols = $activecontrols = []
  end
end

def Log.warning(_message); end

[:frozen, :success, :invalid, :wrong_length, :extra_command, :timeout_before, :timeout_after, :stale].each do |kind|
  fixture = KrowaNativeAnswerAcceptance.new
  begin
    word = [:invalid, :extra_command].include?(kind) ? 'xyz' : kind == :wrong_length ? 'la' : 'las'
    fixture.type(word)
    before = fixture.native.events('Alice').size
    if kind == :frozen
      fixture.screen.instance_variable_set(:@session, fixture.native.session.merge('__frozen' => true))
    elsif kind == :stale
      fixture.native.as('Alice') { fixture.native.transports['Alice'].freeze_game(fixture.native.session, frozen: true) }
    elsif kind.to_s.start_with?('timeout_')
      fixture.native.broker.automatic_delivery = false
      fixture.native.view('Alice').fail_next_push = kind == :timeout_before ? :before : :after
    end
    if kind == :extra_command
      button = fixture.layout.surface.fields.find { |control| control.is_a?(Button) && control.label == 'Add noun to dictionary and check' }
      assert(button, 'Custom noun command is missing')
      fixture.layout.form.index = fixture.layout.form.fields.index(button)
      fixture.layout.form.focus
    end
    fixture.enter
    assert(fixture.field.text == word, 'Choosing an answer cleared it before acceptance')
    if kind == :frozen
      assert(fixture.wait.action.nil?, 'A frozen view admitted the answer')
      assert(fixture.native.events('Alice').size == before, 'A frozen view wrote the answer')
    else
      assert(fixture.wait.action == :game_action, 'Native Enter did not choose the answer')
      accepted = fixture.submit
      if [:success, :extra_command].include?(kind)
        assert(accepted && fixture.field.text.empty?, 'Confirmed write did not clear the original answer')
        assert(fixture.native.events('Alice').size > before, 'The success fixture did not write an event')
        assert(fixture.screen.instance_variable_get(:@surface_state).dig('parts', 'answer', 'text') == '',
          'The next view would restore a stale copy of the sent answer')
        assert(fixture.native.events('Alice').none? { |event| event.to_s.include?('_text_input') },
          'Local input generation leaked into the immutable game log')
      else
        expected = [:invalid, :wrong_length].include?(kind) ? '' : word
        assert(!accepted && fixture.field.text == expected, "#{kind}: wrong rejected draft (accepted=#{accepted.inspect}, text=#{fixture.field.text.inspect}, alerts=#{fixture.alerts.inspect})")
        assert(fixture.native.events('Alice').size == before, 'An invalid answer was written') if [:invalid, :wrong_length].include?(kind)
      end
    end
  ensure
    fixture&.close
  end
end

# A repeated word after an edit is a new draft, even though the letters match.
# Receipt data consists only of copied local scalars, not native controls.
fixture = KrowaNativeAnswerAcceptance.new
begin
  fixture.type('las')
  snapshot = fixture.layout.surface.submission_action
  assert(fixture.field.text == 'las', 'A read-only submission snapshot cleared the text')
  fixture.enter
  original = Marshal.load(Marshal.dump(fixture.selection))
  fixture.field.set_text('')
  fixture.field.restore_selection(index: 0, check: 0)
  fixture.type('las')
  fixture.layout.surface.action_accepted(original)
  assert(fixture.field.text == 'las', 'An old acknowledgement cleared a retyped identical word')
  fixture.field.set_text('dom')
  fixture.layout.surface.action_accepted(original)
  assert(fixture.field.text == 'dom', 'An old acknowledgement cleared a different new answer')
  next_surface = GameSurfaces.build(fixture.native.game.surface_spec(fixture.native.replay('Alice'), 'Alice'))
  next_field = next_surface.fields.first
  next_field.set_text('las')
  next_surface.action_accepted(original)
  assert(next_field.text == 'las', 'A reused question id cleared a different native control')
  current = fixture.layout.surface.submission_action.with_source('answer')
  fixture.layout.session_id += 1
  fixture.screen.send(:confirm_surface_action, fixture.layout.surface, current,
    session_id: fixture.native.session['__id'])
  assert(fixture.field.text == 'dom', 'An old session acknowledgement cleared the current field')
  fixture.layout.session_id = fixture.native.session['__id']
  wrong_question = GameSurfaces::Action.from_h(current.to_h.merge('question_id' => 'krowa-answer-99'))
  fixture.layout.surface.action_accepted(wrong_question)
  assert(fixture.field.text == 'dom', 'An acknowledgement for another question cleared the field')
  fixture.layout.surface.action_accepted(current)
  assert(fixture.field.text.empty?, 'The matching current receipt did not clear the field')
  fixture.type('dom')
  fixture.layout.surface.action_accepted(current)
  assert(fixture.field.text == 'dom', 'A duplicate acknowledgement cleared a new draft')
  fixture.layout.surface.action_guard = -> { false }
  fixture.wait.action = nil
  fixture.enter
  assert(fixture.field.text == 'dom' && fixture.wait.action.nil?, 'A guarded action changed the draft')
ensure
  fixture&.close
end

puts 'PASS native Krowa answer: frozen, stale, before/after lost ACK, confirmed clearing, copied snapshots and new-draft identity'
