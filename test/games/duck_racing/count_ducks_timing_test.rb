require 'json'
require_relative 'challenge_audio_helpers'
require_relative '../../../games/duck_racing_support/challenge_bot'
require_relative '../../support/elten_array_shuffle'
include DuckChallengeAudioTest

# Exercise the production model and player. Only the external sound device
# and monotonic clock are fixtures; duration comes from the actual Opus file.
def count_quack_duration_ms
  bytes = File.binread(File.expand_path('../../../Audio/duck_quack.opus', __dir__))
  header = bytes.index('OpusHead')
  assert(header, 'The count stimulus must use the existing Opus quack')
  assert_equal(1, bytes.getbyte(header + 9))
  assert_equal(48_000, bytes.byteslice(header + 12, 4).unpack1('V'))
  pre_skip = bytes.byteslice(header + 10, 2).unpack1('v')
  offset, granule = 0, nil
  while offset < bytes.bytesize
    assert_equal('OggS', bytes.byteslice(offset, 4))
    granule = bytes.byteslice(offset + 6, 8).unpack1('Q<')
    segments = bytes.getbyte(offset + 26)
    offset += 27 + segments + bytes.byteslice(offset + 27, segments).bytes.sum
  end
  assert_equal(bytes.bytesize, offset)
  Rational(granule - pre_skip, 48)
end

# Reject restarting, seeking or pausing an audible cue. Closing a completed
# attempt is allowed. This observes the existing sound fixture; it does not
# control when the production player advances.
module CountQuackContinuity
  def interruptions; @interruptions ||= []; end
  def record_interruption(action)
    interruptions << action if @started && !@paused && position < length - 0.02
  end
  def position=(value); record_interruption(:seek); super; end
  def play; record_interruption(:restart); super; end
  def pause; record_interruption(:pause); super; end
end

module CountQuackBufferedTail
  attr_accessor :tail_delay_ms
  def position
    return super unless @started
    [[(@program.now_ms - @started - tail_delay_ms.to_i) / 1000.0, 0.0].max, length].min
  end
end

def count_player(state, seat, tail_delay_ms: nil)
  program = Program.new
  program.durations[PLAYER::QUACK_ASSET] = @count_duration.ceil
  program.next_sound = lambda do |sound|
    sound.extend(CountQuackContinuity)
    if tail_delay_ms
      sound.extend(CountQuackBufferedTail)
      sound.tail_delay_ms = tail_delay_ms
    end
  end
  presenter(program) do |action, time|
    accepted = MODEL.submit(state, seat: seat, action: action, now_ms: time)
    assert_equal(action[:kind] == :playback_finished, accepted)
  end
end

def count_state(seed: 31, now_ms: 0)
  MODEL.start('count_ducks', seats: [0, 1], seed: seed, now_ms: now_ms)
end

def count_case(name)
  before = @checks.to_i
  yield
  @count_cases << {name: name, status: 'PASS', checks: @checks.to_i - before}
rescue StandardError => error
  @count_cases << {name: name, status: 'FAIL', checks: @checks.to_i - before,
    error: "#{error.class}: #{error.message}", backtrace: error.backtrace.first(5)}
end

@count_cases = []
@count_duration = count_quack_duration_ms
assert(@count_duration.between?(380, 390), 'The short quack was changed or truncated')

count_case('256 seeds: one tempo per attempt, identical peers and deterministic snapshots') do
  intervals = []
  256.times do |seed|
    state = count_state(seed: seed, now_ms: 6_700)
    first = MODEL.stimulus(state, seat: 0)
    cues = first.fetch(:events)
    assert(cues.length.between?(5, 15))
    assert_equal(0, cues.first[:offset_ms])
    gaps = cues.each_cons(2).map { |a, b| b[:offset_ms] - a[:offset_ms] }
    assert_equal(1, gaps.uniq.length, "Seed #{seed} changes tempo inside one count attempt")
    assert(gaps.first.between?(400, 900))
    intervals << gaps.first
    assert(cues.all? { |cue| cue[:sound] == :quack && cue[:duration_ms] == 400 })
    assert(cues.all? { |cue| cue[:duration_ms] >= @count_duration })
    assert_equal(first, MODEL.stimulus(state, seat: 1))
    assert_equal(first, MODEL.stimulus(count_state(seed: seed, now_ms: 6_700), seat: 0))
    first[:events].first[:offset_ms] = 999
    assert_equal(0, MODEL.stimulus(state, seat: 0)[:events].first[:offset_ms])
    assert_equal(0, MODEL.stimulus(state, seat: 1)[:events].first[:offset_ms])
  end
  assert(intervals.uniq.length > 1, 'Different attempts never change the tempo')
  @count_edge_seeds = [400, 900].to_h do |interval|
    seed = (0...10_000).find do |candidate|
      MODEL.stimulus(count_state(seed: candidate), seat: 0)[:events][1][:offset_ms] == interval
    end
    assert(seed, "No attempt can use the permitted #{interval} ms tempo")
    [interval, seed]
  end
  @count_tempos = {seeds: 256, distinct: intervals.uniq.length, min: intervals.min, max: intervals.max,
    boundary_seeds: @count_edge_seeds}
end

count_case('Both real player instances keep the same tempo and play each full quack') do
  state = count_state(seed: @count_edge_seeds.fetch(400))
  timelines = []
  [230, 1_701].each_with_index do |start_ms, seat|
    audio, program, actions, errors = count_player(state, seat)
    begin
      stimulus = MODEL.stimulus(state, seat: seat)
      assert(audio.play(stimulus))
      stimulus[:events].each_with_index do |cue, index|
        onset = start_ms + cue[:offset_ms]
        at(audio, program, onset)
        assert_equal(index + 1, program.events.length)
        assert_equal(false, audio.play(MODEL.stimulus(state, seat: seat)))
        at(audio, program, onset + @count_duration.ceil - 1)
        assert_equal(index + 1, program.events.length)
        assert_equal(1, actions.length, 'Finished was acknowledged before the last complete quack')
        at(audio, program, onset + @count_duration.ceil)
      end
      assert_equal([:playback_started, :playback_finished], actions.map { |action, _| action[:kind] })
      assert_equal([], errors)
      assert_equal([], program.sounds.flat_map(&:interruptions))
      assert_equal([0] * stimulus[:events].length, program.sounds.first.seeks)
      assert_equal(1, program.sounds.length, 'Count playback leaked sound handles')
      assert_equal(:responding, MODEL.view(state, seat: seat)[:own][:phase])
      assert_equal(program.now_ms + 20_000, MODEL.view(state, seat: seat)[:own][:deadline_ms])
      assert(!audio.busy?)
      timeline = program.events.map { |event| event[:at] - start_ms }
      assert_equal(1, timeline.each_cons(2).map { |a, b| b - a }.uniq.length)
      timelines << timeline
    ensure
      audio.close
    end
    assert_equal([], program.managed)
    assert_equal([1], program.sounds.map(&:closes))
  end
  assert_equal(timelines.first, timelines.last)
end

count_case('Replaying preserves tempo and count without extending the answer deadline') do
  state = count_state(seed: 44)
  audio, program, actions, errors = count_player(state, 0)
  begin
    original = MODEL.stimulus(state, seat: 0)
    audio.play(original)
    at(audio, program, 0)
    drain(audio, program, step: 10)
    deadline = MODEL.view(state, seat: 0)[:own][:deadline_ms]
    replay_at = program.now_ms + 100
    assert(MODEL.submit(state, seat: 0, action: {kind: :replay, press_id: 1}, now_ms: replay_at))
    replay = MODEL.stimulus(state, seat: 0)
    assert_equal(original[:events], replay[:events])
    assert_equal(2, replay[:id])
    assert_equal(replay_at, replay[:requested_ms])
    assert(audio.play(replay))
    at(audio, program, replay_at)
    drain(audio, program, step: 10)
    assert_equal(original[:events].length * 2, program.events.length)
    assert_equal(deadline, MODEL.view(state, seat: 0)[:own][:deadline_ms])
    assert_equal([1, 2], actions.select { |action, _| action[:kind] == :playback_finished }.map { |action, _| action[:playback_id] })
    assert_equal([], errors)
    assert_equal([], program.sounds.flat_map(&:interruptions))
  ensure
    audio.close
  end
end

count_case('A delayed UI frame shifts the following cues and never causes catch-up playback') do
  state = count_state(seed: 61)
  audio, program, actions, errors = count_player(state, 0)
  begin
    stimulus = MODEL.stimulus(state, seat: 0)
    interval = stimulus[:events][1][:offset_ms]
    audio.play(stimulus)
    at(audio, program, 0)
    late = interval * 4 + 73
    at(audio, program, late)
    assert_equal([0, late], program.events.map { |event| event[:at] })
    5.times { at(audio, program, late) }
    assert_equal(2, program.events.length)
    (2...stimulus[:events].length).each do |index|
      next_onset = late + (index - 1) * interval
      at(audio, program, next_onset - 1)
      assert_equal(index, program.events.length, 'A delayed frame compressed the remaining intervals')
      at(audio, program, next_onset)
      assert_equal(index + 1, program.events.length)
    end
    at(audio, program, program.events.last[:at] + @count_duration.ceil)
    assert_equal([], errors)
    assert_equal([], program.sounds.flat_map(&:interruptions))
    assert_equal(:playback_finished, actions.last.first[:kind])
    assert_equal([interval], program.events.drop(1).each_cons(2).map { |a, b| b[:at] - a[:at] }.uniq)
  ensure
    audio.close
  end
end

count_case('A still-draining real-device tail is not truncated at the nominal next onset') do
  state = count_state(seed: 77)
  stimulus = MODEL.stimulus(state, seat: 0)
  interval = stimulus[:events][1][:offset_ms]
  audio, program, actions, errors = count_player(state, 0, tail_delay_ms: interval)
  begin
    audio.play(stimulus)
    full_tail = interval + @count_duration.ceil
    stimulus[:events].length.times do |index|
      onset = index * full_tail
      at(audio, program, onset)
      assert_equal(index + 1, program.events.length)
      at(audio, program, onset + interval)
      assert_equal(index + 1, program.events.length, 'The next quack cut through a device buffer tail')
      assert_equal(1, actions.length)
    end
    at(audio, program, stimulus[:events].length * full_tail)
    assert_equal(stimulus[:events].length, program.events.length)
    assert_equal(:playback_finished, actions.last.first[:kind])
    assert_equal([], errors)
    assert_equal([], program.sounds.flat_map(&:interruptions))
  ensure
    audio.close
  end
end

count_case('Muted game audio keeps the same complete sequence and response deadline') do
  state = count_state(seed: 90)
  audio, program, actions, errors = count_player(state, 0)
  begin
    program.enabled = false
    stimulus = MODEL.stimulus(state, seat: 0)
    audio.play(stimulus)
    at(audio, program, 0)
    drain(audio, program, step: 10)
    assert_equal(stimulus[:events].length, program.events.length)
    assert(program.events.all? { |event| event[:volume] == 0.0 })
    assert_equal(:playback_finished, actions.last.first[:kind])
    assert_equal(program.now_ms + 20_000, MODEL.view(state, seat: 0)[:own][:deadline_ms])
    assert_equal([], errors)
  ensure
    audio.close
  end
end

count_case('Count bot acknowledgements follow the nominal full-length final quack') do
  challenge = {id: 7, kind: 'count_ducks', participants: [0, 1], seed: 91}
  stimulus = MODEL.stimulus(count_state(seed: challenge[:seed]), seat: 0)
  nominal_end = stimulus[:events].last[:offset_ms] + stimulus[:events].last[:duration_ms]
  assert_equal(400, stimulus[:events].last[:duration_ms])
  assert(nominal_end >= stimulus[:events].last[:offset_ms] + @count_duration)
  [0, 1].each do |seat|
    trace = GameRoomDuckRacing::ChallengeBot.plan(challenge, seat: seat, seed: 94)
    finish = trace.fetch('actions').find { |entry| entry.fetch('input')['kind'] == 'playback_finished' }
    assert(finish, 'The bot did not acknowledge count playback')
    assert(finish.fetch('at') >= nominal_end)
  end
end

count_case('An actually interrupted quack remains a technical failure, not a completed count') do
  state = count_state(seed: 94)
  audio, program, actions, errors = count_player(state, 0)
  begin
    audio.play(MODEL.stimulus(state, seat: 0))
    at(audio, program, 0)
    program.sounds.first.early_stop = true
    at(audio, program, @count_duration.ceil + 2_000)
    assert_equal([:playback_interrupted], errors.map(&:code))
    assert_equal([:playback_started], actions.map { |action, _| action[:kind] })
    assert_equal(1, program.events.length)
    assert_equal(:listening, MODEL.view(state, seat: 0)[:own][:phase])
    assert_equal(nil, MODEL.view(state, seat: 0)[:own][:deadline_ms])
    assert_equal({}, state[:scores])
    assert(!state[:finished])
  ensure
    audio.close
  end
end

puts JSON.pretty_generate({quack_duration_ms: @count_duration.to_f,
  tempo_samples: @count_tempos, checks: @checks.to_i, cases: @count_cases})
exit(@count_cases.all? { |entry| entry[:status] == 'PASS' } ? 0 : 1)
