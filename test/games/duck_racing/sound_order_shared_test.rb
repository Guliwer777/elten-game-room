require_relative '../../support/duck_challenge_native'
require_relative 'client_helpers'
require_relative '../../../games/duck_racing_support/challenge_bot'

class DuckSoundOrderSharedTest
  include DuckClientTest

  def run
    settlement_and_order
    timeout_and_bot
    native_keys_and_audio
    report('Duck sound ordering: shared first winner, partial progress, caps, native keys and final swap audio')
  end

  def apply_swap(seat, first, second, at:, revision: -1)
    before = Marshal.load(Marshal.dump(@replay))
    state = @replay.state
    press = state[:round][:engine][:last_press][seat] + 1
    input = {'kind' => 'swap', 'value' => first, 'other' => second, 'press_id' => press}
    payload = {'action' => 'input', 'challenge' => 1, 'revision' => revision, 'input' => input, 'at' => 100_000 + at}
    assert(GameRoomDuckRacing::Session.apply(state, payload, seat: seat, moderator: seat.zero?, now_ms: 100_000 + at, resources: resources))
    GameRoomActionPayload.commands('duck_racing', payload).each do |command|
      @replay.accepted_events << {'action' => command.action, 'value' => command.value,
        '__id' => @replay.accepted_events.length + 1, 'actor' => @replay.players[seat]}
    end
    @client.before_wait(@replay, @viewer)
    [before, Marshal.load(Marshal.dump(@replay)), @replay.accepted_events.last]
  end

  def settlement_and_order
    setup_client('sound_order', players: %w[Alice Bob Carol Dan], participants: [0, 1, 2, 3])
    finish_preparation(delay_ms: ENGINE::ORDER_PREPARATION_DELAY_MS)
    @program.events.clear
    start = ENGINE::ORDER_PREPARATION_MS
    engine = @replay.state[:round][:engine]
    players = engine[:model][:private][:players]
    players[0][:arrangement] = [2, 1, 3, 4, 5, 6, 7, 8]
    players[1][:arrangement] = [2, 3, 1, 4, 5, 6, 7, 8]
    players[2][:arrangement] = [8, 7, 6, 5, 4, 3, 2, 1]
    players[3][:arrangement] = [2, 1, 3, 4, 5, 6, 7, 8]
    # Another seat's swap is valid even if its view predates our action.
    apply_swap(1, 1, 3, at: start + 500)
    assert_equal([1, 3, 2, 4, 5, 6, 7, 8], players[1][:arrangement])
    last = apply_swap(0, 1, 2, at: start + 600)
    assert_equal(nil, @replay.state[:round])
    result = @replay.state[:last_resolution]
    assert_equal(0, result[:settlement].winner)
    assert_equal([2, 5, 2], result[:settlement].transfers.map(&:amount))
    assert_equal([0, 2, 8, 2], result[:results].values.map { |value| value[:misplaced] })
    saved = Marshal.dump(@replay.state)
    stale = {'action' => 'input', 'challenge' => 1, 'revision' => 0, 'input' => {'kind' => 'swap', 'value' => 1, 'other' => 2, 'press_id' => 999}}
    assert(!GameRoomDuckRacing::Session.apply(Marshal.load(saved), stale, seat: 3, moderator: false, now_ms: 100_601 + start, resources: resources))
    assert_equal(saved, Marshal.dump(@replay.state))
    # Accepted final cues survive removal of the round; duplicate delivery is quiet.
    2.times { @client.event(last[2], last[0], last[1], @viewer, Repository.new) }
    advance(start + 620)
    advance(start + 900)
    advance(start + 1_180)
    assert_equal(2, @program.events.length)
    assert(@program.events[0][:frequency] < @program.events[1][:frequency])
    assert_equal([], @program.managed)
    balances = {0 => 1, 1 => 1, 2 => 0}
    settled = GameRoomDuckRacing::Settlement.sound_order(balances: balances, winner: 0, misplaced: {0 => 0, 1 => 8, 2 => 3})
    assert_equal({0 => 2, 1 => 0, 2 => 0}, settled.balances)
  ensure
    close
  end

  def timeout_and_bot
    setup_client('sound_order')
    state = @replay.state
    engine = state[:round][:engine]
    assert(!ENGINE.expire(engine, now_ms: 44_999 + ENGINE::ORDER_PREPARATION_MS))
    deadline = 145_000 + ENGINE::ORDER_PREPARATION_MS
    assert_equal('advance', GameRoomDuckRacing::Session.automatic(state, now_ms: deadline))
    action = {'action' => 'advance', 'challenge' => 1, 'revision' => state[:revision]}
    assert(GameRoomDuckRacing::Session.apply(state, action, seat: 0, moderator: true, now_ms: deadline, resources: resources))
    assert_equal(:no_winner, state[:last_resolution][:settlement].outcome)
    assert_equal([], state[:last_resolution][:settlement].transfers)
    close
    setup_client('sound_order')
    engine = @replay.state[:round][:engine]
    now = ENGINE::ORDER_PREPARATION_MS
    8.times do
      break if ENGINE.finished?(engine)
      press = engine[:last_press][0] + 1
      choice = GameRoomDuckRacing::ChallengeBot.choose_sequential(ENGINE.view(engine, seat: 0), seat: 0, seed: 77, press_id: press)
      assert(choice)
      assert(choice[:delay_ms] >= 4_650) if press == 1
      now += choice[:delay_ms]
      assert(ENGINE.submit(engine, seat: 0, action: choice[:action], now_ms: now))
    end
    assert(ENGINE.finished?(engine))
    assert_equal(true, ENGINE.result_for(engine, 0)[:correct])
    assert_equal(false, ENGINE.result_for(engine, 1)[:correct])
  ensure
    close
  end

  def native_keys_and_audio
    @real_controls = true
    setup_client('sound_order')
    driver = DuckChallengeNativeDriver.new
    @surface = GameSurfaces.build(@client.surface_spec(@replay, @viewer))
    @form = driver.form(@surface)
    @client.attach_view(@form, @surface)
    $lastactivecontrols = [@form]
    finish_preparation(delay_ms: ENGINE::ORDER_PREPARATION_DELAY_MS)
    @program.events.clear
    assert(@surface.fields.first.is_a?(Button))
    assert_equal([], @surface.presentation[:options])
    assert_equal(nil, @client.instance_variable_get(:@trace))
    frame = ->(events = [], characters = '') {
      @program.now_ms += 20
      driver.frame(@form, events, characters: characters)
      @client.tick
    }
    frame.call(driver.tap(0x31))
    frame.call
    assert_equal(nil, request, 'A local preview incurred a durable write')
    assert_equal(1, @program.events.length)
    frame.call(driver.tap(0x32, modifiers: [0x10]), '@')
    assert_equal(nil, request)
    frame.call(driver.tap(0x38, modifiers: [0x10]), '*')
    assert_equal([2, 8], request['input'].values_at('value', 'other'))
    assert_equal(1, @client.instance_variable_get(:@inputs).length)
    frame.call(driver.tap(0x0D))
    assert_equal(1, @client.instance_variable_get(:@inputs).length, 'Enter still controls an invisible list')
    frame.call(driver.tap(0x09))
    frame.call(driver.tap(0x31))
    assert_equal(1, @program.events.length, 'Chat digit played a sound')
  ensure
    close
  end
end

DuckSoundOrderSharedTest.new.run
