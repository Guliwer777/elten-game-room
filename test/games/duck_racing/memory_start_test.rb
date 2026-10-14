require_relative '../../support/duck_challenge_native'
require_relative 'client_helpers'
require_relative '../../support/duck_game_adapter'
require_relative '../../../lib/game_event_presenter'

class DuckMemoryStartTest
  include DuckClientTest

  def run
    %w[Alice Bob].each { |first| readiness(first) }
    report('Duck memory readiness: both native Enter keys, shared start and named first player')
  end

  def readiness(first)
    @driver = DuckChallengeNativeDriver.new
    h = DuckGameAdapterTest::Harness.new(kind: 'sound_memory')
    id = h.open_round(group: false)[:id]
    @program = DuckChallengeAudioTest::Program.new
    @copies = %w[Alice Bob Observer].to_h do |viewer|
      client = CLIENT.new(@program, h.game, clock: -> { @program.now_ms / 1000.0 },
        session_time: ->(_state) { h.now_ms },
        realtime_factory: -> { Realtime.new(@program) },
        progress_factory: ->(**_options, &block) { Progress.new(&block) })
      client.bind_screen(session_id: 91, table_id: 41, owner: 'Alice', viewer: viewer, members: -> { h.players })
      client.start
      client.update_table_control(h.session)
      client.before_wait(h.replay, viewer)
      surface = GameSurfaces.build(client.surface_spec(h.replay, viewer))
      form = @driver.form(surface)
      client.attach_view(form, surface)
      [viewer, {client: client, surface: surface, form: form}]
    end
    @copies.each_value do |copy|
      assert(copy[:surface].presentation[:practice])
      assert_equal(false, copy[:client].context_data['duck_ready'])
    end
    selection = ->(viewer) { h.game.automatic_action(h.replay, viewer,
      context: h.context(viewer, local: @copies[viewer][:client].context_data)) }
    h.players.each { |viewer| assert_equal(nil, selection.call(viewer), 'Ready was sent without Enter') }
    press('Observer', 0x0D)
    assert_equal(false, @copies['Observer'][:client].context_data['duck_ready'])
    press(first, 0x31)
    assert_equal([], @program.events, 'Preparation revealed a hidden sound')
    press(first, 0x09) # chat
    press(first, 0x0D)
    assert_equal(false, @copies[first][:client].context_data['duck_ready'], 'Chat Enter started the challenge')
    press(first, 0x09) # game field
    press(first, 0x0D)
    assert_equal('ready', selection.call(first)&.[]('action'))
    h.accept(selection.call(first), actor: first)
    refresh(h)
    assert_equal(nil, h.replay.state[:round][:engine], 'One Enter started the game')
    assert_equal(nil, GameRoomDuckRacing::Session.automatic(h.replay.state, now_ms: h.now_ms))
    assert_equal(nil, selection.call(first), 'Repeated readiness was queued')
    press(first, 0x0D)
    assert_equal(nil, selection.call(first))
    second = (h.players - [first]).first
    assert_equal(false, @copies[second][:client].context_data['duck_ready'])
    messages = []
    presenter = GameRoomEventPresenter.new(game: -> { h.game }, repository: -> { h.repository },
      program: -> { @program }, viewer: -> { 'Alice' }, client: -> { @copies['Alice'][:client] },
      surface_state: -> { {} }, clock: -> { @program.now_ms / 1000.0 }, covered: -> { false },
      speech: ->(text) { messages << text }, trace: ->(*_args, **_options) {},
      history_changed: ->(*_args) {}, session_changed: -> {})
    presenter.process_new_events(h.replay, session: h.session)
    messages.clear
    press(second, 0x0D)
    h.accept(selection.call(second), actor: second)
    SpeechOutput.reset
    presenter.process_new_events(h.replay, session: h.session)
    refresh(h)
    player = h.players.fetch(ENGINE.current_turn(h.replay.state[:round][:engine]))
    assert_equal(["#{player}'s turn."], messages, 'Beginning did not identify exactly one starter')
    assert_equal([], SpeechOutput.calls, 'Local activation duplicated the start announcement')
    assert_equal(:playing, h.replay.state[:round][:phase])
    @copies.each_value { |copy| assert(!copy[:client].local_view[:practice]) }
    before = messages.dup
    presenter.process_new_events(h.replay, session: h.session)
    assert_equal(before, messages, 'Refresh repeated the first player')
    assert_equal(id, h.replay.state[:round][:challenge][:id])
  ensure
    presenter&.event_presentation&.close
    @copies&.each_value { |copy| copy[:client].close }
    assert_equal([], @program.managed)
  end

  def press(viewer, code)
    copy = @copies.fetch(viewer)
    if @active_viewer != viewer
      @active_viewer = viewer
      $lastactivecontrols = [copy[:form]]
      @driver.frame(copy[:form])
      copy[:client].tick
    end
    @program.now_ms += 20
    $lastactivecontrols = [copy[:form]]
    @driver.frame(copy[:form], @driver.tap(code))
    copy[:client].tick
  end

  def refresh(h)
    @copies.each do |viewer, copy|
      copy[:client].before_wait(h.replay, viewer)
      copy[:client].tick
    end
  end
end

DuckMemoryStartTest.new.run
