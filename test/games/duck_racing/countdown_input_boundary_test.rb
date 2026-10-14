require 'json'
require_relative '../../support/duck_challenge_native'
require_relative 'client_helpers'

class DuckCountdownBoundaryTest
  include DuckClientTest

  def run
    @real_controls = true
    @driver = DuckChallengeNativeDriver.new
    results = [:fixed_pause, :first_digit, :detached_input].map do |name|
      begin
        send(name)
        {case: name, status: 'PASS'}
      rescue StandardError => error
        {case: name, status: 'FAIL', error: "#{error.class}: #{error.message}", backtrace: error.backtrace.first(4)}
      ensure
        close
        $lastactivecontrols = []
      end
    end
    puts JSON.pretty_generate(results: results, checks: @checks)
    raise 'Countdown input boundary failed' unless results.all? { |result| result[:status] == 'PASS' }
  end

  def setup(kind = 'copy_number')
    setup_client(kind)
    @surface = GameSurfaces.build(@client.surface_spec(@replay, @viewer))
    @form = @driver.form(@surface)
    @client.attach_view(@form, @surface)
    $lastactivecontrols = [@form]
    @field = @surface.fields.first
    # This path must not query or wait for the synthesizer, even if it is
    # permanently busy or its implementation cannot report completion.
    @client.define_singleton_method(:speech_actived) { raise 'Do not query speech for the countdown' }
  end

  def frame(at, events: [], held: [], characters: '')
    @program.now_ms = at
    @driver.frame(@form, events, held: held, characters: characters)
    @client.tick
  end

  def cues
    @program.events.select { |event| event[:asset] == 'duck_countdown' }
  end

  def fixed_pause
    setup
    frame(0)
    frame(4_999)
    assert_equal([], cues, 'The recording did not wait five seconds after the instruction')
    frame(5_000)
    assert_equal([5_000], cues.map { |cue| cue[:at] })
    3.times { replace; @client.tick }
    assert_equal(1, cues.length, 'A refresh replayed the countdown')
  end

  def before_end(kind = 'copy_number', held: false)
    setup(kind)
    frame(0)
    frame(5_000) if cues.empty?
    cue = cues.fetch(0)
    boundary = cue[:at] + (cue[:sound].length * 1000).round
    if held
      frame(boundary - 30, events: [[0x31, true]], held: [0x31])
    end
    frame(boundary - 1, events: held ? [[0x31, :repeat]] : [], held: held ? [0x31] : [])
    assert(@client.local_view[:preparing])
    boundary
  end

  def first_digit
    boundary = before_end
    trace = @client.instance_variable_get(:@trace)
    answer = trace.state[:model][:answer].to_s
    frame(boundary, events: @driver.tap(answer.getbyte(0)), characters: answer[0])
    assert_equal(answer[0], @field.text, 'The first digit after playback ended was discarded by the read-only field')
    assert(!@client.local_view[:preparing])
    frame(boundary + 20, events: answer[1..].chars.flat_map { |digit| @driver.tap(digit.ord) }, characters: answer[1..])
    assert_equal('submit_trace', request && request['action'])
    assert_equal(answer, request['trace']['actions'].last['input']['value'])
    assert_equal(20, request['trace']['finished_at'], 'The pause or cue was included in response time')
  end

  def detached_input
    setup
    @client.detach_view
    assert_equal(nil, @surface.before_input, 'The old field retains the client after detaching')
  end
end

DuckCountdownBoundaryTest.new.run
