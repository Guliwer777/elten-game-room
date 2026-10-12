require_relative '../../support/duck_challenge_native'
require_relative 'client_helpers'

class DuckSoundOrderStartTest
  include DuckClientTest

  def run
    model_start
    native_start
    cleanup_and_observer
    report('Duck sound ordering start: shared boundary, 2s silence, actual cue completion, refresh and cleanup')
  end

  def model_start
    setup_client('sound_order')
    engine = @replay.state[:round][:engine]
    assert_equal(ENGINE::ORDER_PREPARATION_MS, ENGINE.view(engine, seat: 0)[:started_ms])
    [0, 1].each do |seat|
      saved = Marshal.dump(engine)
      input = {kind: :swap, value: 1, other: 2, press_id: 1}
      assert(!ENGINE.submit(engine, seat: seat, action: input, now_ms: ENGINE::ORDER_PREPARATION_MS - 1))
      assert_equal(saved, Marshal.dump(engine), 'An early swap changed accepted state')
      assert(ENGINE.submit(engine, seat: seat, action: input, now_ms: ENGINE::ORDER_PREPARATION_MS))
    end
  ensure
    close
  end

  def native_start
    @real_controls = true
    @driver = DuckChallengeNativeDriver.new
    setup_client('sound_order')
    @surface = GameSurfaces.build(@client.surface_spec(@replay, @viewer))
    @form = @driver.form(@surface)
    @client.attach_view(@form, @surface)
    $lastactivecontrols = [@form]
    frame(0)
    assert(@surface.presentation[:instruction].include?('1 to 8'))
    assert(@client.local_view[:preparing])
    frame(1, @driver.tap(0x31))
    frame(1_999, @driver.tap(0x32, modifiers: [0x10]))
    assert_equal([], @program.events)
    assert_equal(nil, request)
    frame(2_000)
    assert_equal(['duck_countdown'], @program.events.map { |entry| entry[:asset] })
    assert_equal(2_000, @program.events.first[:at])
    replace { |replay| replay.state[:round][:last_seen][1] += 10 }
    frame(3_000)
    frame(ENGINE::ORDER_PREPARATION_MS - 1, @driver.tap(0x31))
    assert_equal(1, @program.events.length)
    frame(ENGINE::ORDER_PREPARATION_MS, @driver.tap(0x31))
    assert_equal(:preview, @surface.instance_variable_get(:@pending).first[:kind])
    frame(ENGINE::ORDER_PREPARATION_MS + 20)
    frame(ENGINE::ORDER_PREPARATION_MS + 40)
    assert(!@client.local_view[:preparing])
    assert_equal(%w[duck_countdown duck_note_c], @program.events.map { |entry| entry[:asset] },
      'A fresh digit at the end of the countdown was lost')
    assert_equal(nil, request, 'Early swaps leaked into the active challenge')
    frame(ENGINE::ORDER_PREPARATION_MS + 60, @driver.tap(0x31, modifiers: [0x10]))
    frame(ENGINE::ORDER_PREPARATION_MS + 80, @driver.tap(0x32, modifiers: [0x10]))
    assert_equal([1, 2], request['input'].values_at('value', 'other'))
    assert_equal(1, @program.events.count { |entry| entry[:asset] == 'duck_countdown' })
  ensure
    close
    @real_controls = false
  end

  def frame(at, events = [])
    @program.now_ms = at
    @driver.frame(@form, events)
    @client.tick
  end

  def cleanup_and_observer
    setup_client('sound_order')
    advance(2_000)
    sound = @program.events.first[:sound]
    close
    assert(sound.closed?)
    assert_equal([], @program.managed)

    setup_client('sound_order', viewer: 'Charlie')
    advance(2_000)
    advance(ENGINE::ORDER_PREPARATION_MS)
    assert_equal([], @program.events, 'An observer received an extra start countdown')
    assert_equal(nil, request)
    close

    setup_client('sound_order')
    # A device completing late must not enable input at the nominal deadline.
    @program.durations['duck_countdown'] += 300
    advance(2_000)
    @surface.push(:preview, value: 1)
    advance(ENGINE::ORDER_PREPARATION_MS)
    assert(@client.local_view[:preparing])
    assert_equal(1, @program.events.length)
    advance(ENGINE::ORDER_PREPARATION_MS + 300)
    assert(!@client.local_view[:preparing])
    advance(ENGINE::ORDER_PREPARATION_MS + 320)
    assert_equal(1, @program.events.length, 'An early preview was queued')
  ensure
    close
  end
end

DuckSoundOrderStartTest.new.run
