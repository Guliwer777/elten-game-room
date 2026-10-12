# frozen_string_literal: true

require_relative '../../support/duck_game_adapter'
require_relative 'client_helpers'
require_relative '../../../lib/game_event_presenter'

class DuckChallengeIntroductionTest
  include DuckClientTest
  HARNESS = DuckGameAdapterTest::Harness

  def run
    assets
    GameRoomDuckRacing::Challenges::BY_ID.each_key { |kind| challenge_card(kind) }
    question_card
    square_question_and_encounter
    sound_policy
    client_preparation('copy_number', delay: 0)
    client_preparation('guess_number', delay: 2_000)
    client_preparation('count_ducks', delay: 2_000)
    client_preparation('quiz', delay: 2_000, question: :card)
    client_preparation('quiz', delay: 3_000, question: :square)
    report('Duck introductions: distinct encounter/question cues, fixed 2s after card/landing, input readiness, no stacked pause, snapshots and sound policy')
  ensure
    @output&.close
    DuckChallengeAudioTest::Program.settings = {}
    close
  end

  def assets
    root = File.expand_path('../../..', __dir__)
    manifest = JSON.parse(File.read(File.join(root, 'manifest.json'), encoding: 'UTF-8'))
    source = File.read(File.join(root, '__app.rb'), encoding: 'UTF-8')
    embedded = JSON.parse(source.split("=begin Elten3AppInfo\n", 2).last.split("\n=end", 2).first)
    assert_equal(manifest['required_assets'], embedded['required_assets'])
    assert_equal(1, manifest['required_assets']['sounds'].count('duck_challenge'))
    assert_equal(1, GameRoomSounds::ASSET_NAMES.count('duck_challenge'))
    assert_equal(0.544, GameRoomSounds::ASSET_VOLUME_GAINS.fetch('duck_challenge'))
    files = Dir.glob(File.join(root, 'Audio', 'duck_challenge.*'))
    assert_equal([File.join(root, 'Audio', 'duck_challenge.opus')], files)
    bytes = File.binread(files.first)
    assert(bytes.start_with?('OggS') && bytes.include?('OpusHead'))
    assert_equal(1, bytes.getbyte(bytes.index('OpusHead') + 9), 'Conversion changed the mono source')
    %w[duck_question duck_correct duck_frozen].each do |asset|
      assert_equal(1, manifest['required_assets']['sounds'].count(asset))
      assert_equal(1, GameRoomSounds::ASSET_NAMES.count(asset))
      bytes = File.binread(File.join(root, 'Audio', "#{asset}.opus"))
      assert(bytes.start_with?('OggS') && bytes.include?('OpusHead'))
      assert_equal(2, bytes.getbyte(bytes.index('OpusHead') + 9), 'Conversion changed the stereo source')
    end
    assert_equal(0.7, GameRoomSounds::ASSET_VOLUME_GAINS.fetch('duck_question'))
  end

  def presenter(h, viewer: 'Alice', program: nil, client: nil)
    @program = program || DuckChallengeAudioTest::Program.new
    @program.durations['duck_question'] = 2_485
    @spoken = []
    @covered = false
    GameRoomEventPresenter.new(game: -> { h.game }, repository: -> { h.repository },
      program: -> { @program }, viewer: -> { viewer }, client: -> { client }, surface_state: -> { {} },
      clock: -> { @program.now_ms / 1000.0 }, covered: -> { @covered },
      speech: ->(text) { @spoken << [@program.now_ms, text] }, trace: ->(*_args, **_options) {},
      history_changed: ->(*_args) {}, session_changed: -> {})
  end

  def emit(p, h, replay = h.replay)
    p.process_new_events(replay, session: h.session, background: @covered)
  end

  def encounters
    @program.events.select { |event| event[:asset] == 'duck_challenge' }
  end

  def challenge_card(kind)
    h = HARNESS.new(kind: kind)
    h.start(seed: h.seed_for('challenge'))
    p = presenter(h)
    before = h.replay
    emit(p, h, before)
    first = h.events.length
    h.open_round(group: false)
    (first...h.events.length).each do |index|
      emit(p, h, h.game.replay(h.session, h.events.take(index), h.repository))
      assert_equal([], encounters, "#{kind}: an incomplete payload played the encounter cue")
    end
    after = h.replay
    emit(p, h, after)
    assert_equal(1, encounters.length, "#{kind}: missing or duplicate encounter cue")
    assert_equal(@program.gain * 0.544, encounters.first[:volume])
    entry = after.history.find { |value| value.kind == :challenge }
    assert_equal("Alice starts a challenge with Bob.\n#{h.game.challenge_name(kind)}.", entry.text)
    immediate_countdown = kind == 'sound_order' || ENGINE::SPEED_TYPES.include?(kind) && kind != 'count_ducks'
    assert_equal(!immediate_countdown, p.event_presentation_busy?, "#{kind}: incorrect introduction pause")
    unless immediate_countdown
      @program.now_ms = 1_999
      p.event_presentation.advance
      assert(p.event_presentation_busy?, "#{kind}: introduction ended early")
      @program.now_ms = 2_000
      p.event_presentation.advance
      assert(!p.event_presentation_busy?, "#{kind}: introduction lasted over two seconds")
    end
    3.times { emit(p, h, after) }
    emit(p, h, before)
    assert_equal(1, encounters.length, "#{kind}: refresh repeated the encounter cue")
    assert_equal(DuckGameAdapterTest.semantic(after.state), DuckGameAdapterTest.semantic(h.replay.state))
    cold = presenter(h, viewer: 'Watcher')
    emit(cold, h)
    assert_equal([], encounters, "#{kind}: joining replayed an old encounter")
    assert(!cold.event_presentation_busy?, "#{kind}: joining delayed an existing challenge")
  end

  def question_card
    h = HARNESS.new(kind: 'dice_duel', count: 3)
    h.start(seed: h.seed_for('curiosity'))
    p = presenter(h)
    emit(p, h)
    card = h.replay.state[:race][:racers][0][:hand].find { |copy| copy.type == 'curiosity' }
    h.accept({'action' => 'race', 'input' => {'kind' => 'play', 'card' => card.id}}, actor: 'Alice')
    emit(p, h)
    assert_equal(:question_card, h.replay.state[:round][:challenge][:trigger])
    assert_equal([0, 1, 2], h.replay.state[:round][:challenge][:participants])
    assert_equal(['Question for everyone.'], h.replay.history.select { |entry| entry.kind == :quiz_question }.map(&:text))
    assert(!h.replay.history.any? { |entry| entry.kind == :challenge })
    assert_equal(%w[play duck_question], @program.events.map { |entry| entry[:asset] })
    assert_equal(@program.gain * 0.7, @program.events.last[:volume])
    @program.now_ms = 1_999
    p.event_presentation.advance
    assert(p.event_presentation_busy?, 'The question introduction ended early')
    @program.now_ms = 2_000
    p.event_presentation.advance
    assert(!p.event_presentation_busy?, 'The question waited longer than the fixed pause')
    assert(@program.events.last[:sound].playing?, 'Fixture must include a recording longer than the pause')
    3.times { emit(p, h) }
    assert_equal(%w[play duck_question], @program.events.map { |entry| entry[:asset] })
  end

  def square_question_and_encounter
    # Exercise actual board effects, including a question followed by meeting
    # a duck on that square. Both openings use quiz, but have distinct origins.
    state = GameRoomDuckRacing::Race.start(player_count: 2, laps: 3, seed: 17, enabled_challenges: ['quiz'])
    state[:racers][0][:progress], state[:racers][1][:progress] = 5, 6
    state[:occupants] = {6 => [0], 7 => [1]}
    state[:random] = Random.new((0..100).find { |seed| Random.new(seed).rand(6).zero? })
    race = GameRoomDuckRacing::Race.new(state)
    assert(race.apply(seat: 0, revision: 0, action: {kind: :roll}))
    assert_equal(:square_question, state[:challenge][:trigger])
    game = HARNESS.new.game
    render = -> { [].tap { |history| game.send(:append_notices, history, state[:notices], 7, %w[Alice Bob]) } }
    history = render.call
    assert_equal(1, history.count { |entry| entry.kind == :quiz_question })
    assert_equal([], history.filter_map { |entry| game.class::EVENT_SOUNDS[entry.kind] } & ['duck_challenge'])
    assert_equal(['duck_question'], history.filter_map { |entry| game.class::EVENT_SOUNDS[entry.kind] } & ['duck_question'])
    replay = GameRoomGames::Replay.new(players: %w[Alice Bob], history: history,
      state: {race: state, round: {challenge: state[:challenge]}})
    stages = game.event_presentation_stages({'id' => 7}, HARNESS.new.repository, nil, replay, 'Alice')
    assert_equal([1.0, 2.0], stages.map { |stage| stage[:delay] }, 'A square needs its question pause after the roll and landing')
    balances = state[:racers].transform_values { |racer| racer[:feathers] }
    result = GameRoomDuckRacing::Settlement.fixed(balances: balances, winner: nil, amount: 0)
    assert(race.complete_challenge(id: state[:challenge][:id], result: result))
    assert_equal(:encounter, state[:challenge][:trigger])
    history = render.call
    assert_equal([:challenge_result, :challenge], history.map(&:kind))
    assert_equal("Alice starts a challenge with Bob.\nQuiz.", history.last.text)
    assert_equal(['duck_challenge'], history.filter_map { |entry| game.class::EVENT_SOUNDS[entry.kind] })
    replay = GameRoomGames::Replay.new(players: %w[Alice Bob], winner: nil, draw: false, history: history,
      state: {race: state, round: {challenge: state[:challenge]}, last_resolution: {settlement: result}})
    stages = game.event_presentation_stages({'id' => 7}, HARNESS.new.repository, nil, replay, 'Alice')
    assert_equal([2.0, 2.0], stages.map { |stage| stage[:delay] }, 'Result pause swallowed the next encounter introduction')
  end

  def sound_policy
    [:observer, :disabled, :covered].product([false, true]).each do |mode, question|
      h = HARNESS.new
      h.start(seed: h.seed_for(question ? 'curiosity' : 'super_challenge'))
      p = presenter(h, viewer: mode == :observer ? 'Watcher' : 'Alice')
      @output = GameRoomSoundOutput.new(@program, audio_game: false, covered: -> { @covered })
      emit(p, h)
      @program.gain = 0.25
      @program.enabled = mode != :disabled
      @covered = mode == :covered
      @program.class.settings = {'background_game_sounds' => 'all'} if @covered
      if question
        play_question(h)
      else
        h.open_round
      end
      emit(p, h)
      cues = @program.events.select { |event| event[:asset] == (question ? 'duck_question' : 'duck_challenge') }
      assert_equal(mode == :disabled ? 0 : 1, cues.length)
      assert_equal(mode == :covered ? 0.0 : 0.25 * (question ? 0.7 : 0.544), cues.first[:volume]) unless mode == :disabled
      @covered = false
      @output.tick
      assert_equal(0.0, cues.first[:sound].volume) if mode == :covered
      @output.close
      @program.class.settings = {}
    end
  end

  def play_question(h)
    card = h.replay.state[:race][:racers][0][:hand].find { |copy| copy.type == 'curiosity' }
    h.accept({'action' => 'race', 'input' => {'kind' => 'play', 'card' => card.id}}, actor: 'Alice')
  end

  def square_seed
    (1..100).find do |seed|
      state = GameRoomDuckRacing::Race.start(player_count: 2, laps: 3, seed: seed, enabled_challenges: ['quiz'])
      GameRoomDuckRacing::Race.new(state).apply(seat: 0, revision: 0, action: {kind: :roll})
      state.dig(:challenge, :trigger) == :square_question
    end || raise('No natural roll to the question square')
  end

  def client_preparation(kind, delay:, question: nil)
    pending, p = true, nil
    setup_client(kind, phase: :preparing, presentation_busy: -> { pending || p.event_presentation_busy? })
    h = HARNESS.new(kind: kind)
    @game.resources = h.resources
    h.start(seed: question == :square ? square_seed : h.seed_for(question ? 'curiosity' : 'challenge'))
    p = presenter(h, program: @program, client: @client)
    emit(p, h)
    if question == :card
      play_question(h)
    elsif question == :square
      h.accept({'action' => 'race', 'input' => {'kind' => 'roll'}}, actor: 'Alice')
    else
      h.open_round(group: false)
    end
    emit(p, h)
    @replay = h.replay
    control
    @client.before_wait(@replay, @viewer)
    pending = false
    if question == :square
      advance(1_000)
      p.event_presentation.advance
      assert_equal([1_000], @program.events.select { |event| event[:asset] == 'duck_question' }.map { |event| event[:at] })
    end
    if delay.positive?
      advance(delay - 1)
      p.event_presentation.advance
      assert_equal(0, @game.loads, 'Client prepared the challenge before the encounter pause')
      assert_equal(nil, @client.local_view, 'Question or controls were exposed during the introduction')
      assert_equal(false, @client.context_data['duck_ready'])
      assert(@program.events.none? { |event| event[:asset] == 'duck_quack' }, 'A duck played during the introduction')
    end
    @program.now_ms = delay
    p.event_presentation.advance
    advance(delay)
    assert_equal(1, @game.loads)
    h.begin_round
    emit(p, h)
    @replay = h.replay
    control
    @client.before_wait(@replay, @viewer)
    attach
    assert_equal(delay, @client.instance_variable_get(:@origin_ms), 'Attempt time included the encounter pause')
    if question
      assert_equal('quiz', @client.local_view[:type])
      assert_equal(20_000, @client.local_view[:deadline_ms], 'The introduction consumed question answer time')
      assert_equal([question == :square ? 1_000 : 0],
        @program.events.select { |event| event[:asset] == 'duck_question' }.map { |event| event[:at] })
      assert(@program.events.none? { |event| event[:asset] == 'duck_challenge' })
    end
    if kind == 'count_ducks'
      advance(delay)
      quacks = -> { @program.events.select { |event| event[:asset] == 'duck_quack' } }
      assert_equal([delay], quacks.call.map { |event| event[:at] }, 'The first duck did not wait for the introduction')
      4_000.times do
        break if @client.local_view[:preparing]
        advance(@program.now_ms + 10)
      end
      assert(@client.local_view[:preparing], 'The completed ducks did not prepare the answer phase')
      assert(@program.sounds.none?(&:playing?), 'The answer pause overlapped the final duck')
      playback_end = @program.now_ms
      cues = -> { @program.events.select { |event| event[:asset] == 'duck_countdown' } }
      assert_equal([], cues.call)
      advance(playback_end + 2_499)
      assert_equal([], cues.call, 'Introduction shortened the pause before answering')
      advance(playback_end + 2_500)
      assert_equal([playback_end + 2_500], cues.call.map { |event| event[:at] })
      advance(playback_end + ENGINE::PREPARATION_MS)
      assert_equal(:responding, @client.local_view.dig(:own, :phase))
      assert_equal(playback_end - delay + ENGINE::PREPARATION_MS + 20_000,
        @client.local_view.dig(:own, :deadline_ms), 'Introduction consumed the answer deadline')
    elsif ENGINE::SPEED_TYPES.include?(kind)
      advance(2_499)
      assert(@program.events.none? { |event| event[:asset] == 'duck_countdown' })
      advance(2_500)
      assert_equal([2_500], @program.events.select { |event| event[:asset] == 'duck_countdown' }.map { |event| event[:at] })
      advance(2_500 + ENGINE::COUNTDOWN_MS)
      assert(!@client.local_view[:preparing], 'Speed challenge added another two seconds')
    end
    close
  end
end

DuckChallengeIntroductionTest.new.run
