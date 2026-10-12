require 'fileutils'
require_relative '../../support/duck_game_adapter'
require_relative 'client_helpers'
require_relative '../../../lib/game_event_presenter'

class DuckSoundsTest
  include DuckClientTest
  HARNESS = DuckGameAdapterTest::Harness

  def run
    @results = []
    check('accepted race events, payload fragments, snapshots and spectator') { persisted_events }
    check('card effects and played/placed deduplication') { card_effects }
    check('freezing and frozen skip, distinct from ordinary skip; deduplication and audio policy') { frozen_turns }
    check('ready, alive, private commits/reveals are silent') { private_history }
    check('game gain, disabled sounds, background mute and no catch-up') { sound_policy }
    check('accepted duel roll, duplicate input and deadline roll') { duel_sounds }
    check('risky dice roll, save, rejected input and refresh') { risky_dice_sounds }
    check('blackjack initial deal, draw, stand and new challenge') { blackjack_sounds }
    check('challenge gain, disabled sounds, covered deadline and observer') { local_policy }
    check('listening challenges receive no dice/card effects') { listening_challenges }
    raise 'No sound scenarios matched DUCK_SOUNDS_CASE' if @results.empty?
    FileUtils.mkdir_p('tmp/duck-racing')
    File.write('tmp/duck-racing/sounds-local.json', JSON.pretty_generate(
      checks: @checks, scenarios: @results, note: 'Local models, presenter and managed output; device recording fixture, not live audio.'))
    @results.each { |result| puts "#{result[:status]} #{result[:name]}#{result[:error] ? ": #{result[:error]}" : ''}" }
    raise 'Duck sounds regression failed' if @results.any? { |result| result[:status] != 'PASS' }
    report('Duck race, accepted public dice/card sounds and private audio isolation')
  end

  def check(name)
    return if ENV['DUCK_SOUNDS_CASE'] && !Regexp.new(ENV.fetch('DUCK_SOUNDS_CASE')).match?(name)

    yield
    @results << {name: name, status: 'PASS'}
  rescue StandardError => error
    @results << {name: name, status: 'FAIL', error: "#{error.class}: #{error.message}", location: error.backtrace.first(5)}
  ensure
    @output&.close
    @output = nil
    @program.class.settings = {} if @program
    close
  end

  def build_presenter(harness, viewer: 'Alice')
    @program = DuckChallengeAudioTest::Program.new
    @covered = false
    @output = GameRoomSoundOutput.new(@program, audio_game: true, covered: -> { @covered })
    GameRoomEventPresenter.new(game: -> { harness.game }, repository: -> { harness.repository },
      program: -> { @program }, viewer: -> { viewer }, client: -> { nil }, surface_state: -> { {} },
      clock: -> { @program.now_ms / 1000.0 }, covered: -> { @covered }, speech: ->(_text) {},
      trace: ->(*_args, **_options) {}, history_changed: ->(*_args) {}, session_changed: -> {})
  end

  def emit(presenter, harness, replay = harness.replay)
    presenter.process_new_events(replay, session: harness.session, background: @covered)
  end

  def names
    @program.events.map { |event| event[:asset] }
  end

  def cue(harness, event, before, after, viewer: 'Alice')
    GameRoomSounds.event_cue(game: harness.game, event: event, before_replay: before,
      after_replay: after, repository: harness.repository, viewer: viewer)
  end

  def play_card(harness, type)
    card = harness.replay.state[:race][:racers][0][:hand].find { |copy| copy.type == type }
    assert(card, "Missing fixture card #{type}")
    input = {'kind' => 'play', 'card' => card.id}
    input['target'] = 1 if GameRoomDuckRacing::Cards::BY_ID[type].target == :opponent
    harness.accept({'action' => 'race', 'input' => input}, actor: 'Alice')
  end

  def persisted_events
    ['Alice', 'Bob', 'Watcher'].each do |viewer|
      h = HARNESS.new
      presenter = build_presenter(h, viewer: viewer)
      emit(presenter, h)
      assert_equal([], names)
      h.start(seed: h.seed_for('good_draw'))
      assert(h.events.length > 1, 'The start must cross real payload fragments')
      h.events.length.times do |index|
        partial = h.game.replay(h.session, h.events.take(index), h.repository)
        emit(presenter, h, partial)
        assert_equal([], names, 'Incomplete start played a sound')
      end
      started = h.replay
      emit(presenter, h, started)
      assert_equal(['shuffle'], names)
      before_length = h.events.length
      play_card(h, 'good_draw')
      full = h.replay
      (before_length...h.events.length).each do |index|
        emit(presenter, h, h.game.replay(h.session, h.events.take(index), h.repository))
        assert_equal(['shuffle'], names, 'An incomplete action played a card')
      end
      emit(presenter, h, full)
      assert_equal(%w[shuffle play draw], names)
      3.times { emit(presenter, h, full) }
      emit(presenter, h, started)
      assert_equal(%w[shuffle play draw], names, 'A repeated or old snapshot replayed audio')
      @covered = true
      @program.class.settings = {'background_game_sounds' => 'never', 'background_turn_sound' => false}
      h.accept({'action' => 'race', 'input' => {'kind' => 'roll'}}, actor: 'Alice')
      before = names.length
      emit(presenter, h)
      assert_equal(1, names.drop(before).count('roll'), 'A covered roll was not presented once')
      @covered = false
      emit(presenter, h)
      assert_equal(1, names.drop(before).count('roll'), 'Returning replayed the covered roll')
      @output.close
    end
  end

  def card_effects
    {'good_draw' => %w[play draw], 'card_rob' => %w[play draw],
      'hand_switch' => %w[play card-shuffle], 'hand_mix' => %w[play card-shuffle],
      'mine' => ['play'], 'golden_sleep' => ['play'], 'repairing_rest' => ['play']}.each do |type, expected|
      h = HARNESS.new
      h.start(seed: h.seed_for(type))
      before, first = h.replay, h.events.length
      play_card(h, type)
      after = h.replay
      fragments = h.events.drop(first)
      assert(fragments.length > 1, 'Fixture needs a multipart action')
      assert_equal(expected, Array(cue(h, fragments.last, before, after)), "Wrong cue for #{type}")
      assert_equal(expected, Array(cue(h, fragments.last, before, after, viewer: 'Watcher')))
      assert_equal(nil, cue(h, fragments.first, before, after), 'An earlier payload part played a sound')
      if type == 'mine'
        kinds = after.history.select { |entry| entry.event_id == h.events.last['id'] }.map(&:kind)
        assert_equal(1, kinds.count(:placed), 'The actual card placement must retain its play cue')
        assert_equal(0, kinds.count(:played), 'Card placement repeated the generic play announcement')
      elsif type == 'repairing_rest'
        before = after
        h.accept({'action' => 'race', 'input' => {'kind' => 'skip'}}, actor: 'Alice')
        assert_equal('skip', cue(h, h.events.last, before, h.replay))
      end
    end
  end

  def private_history
    h = HARNESS.new
    h.open_round
    presenter = build_presenter(h)
    emit(presenter, h)
    assert_equal([], names, 'Joining replayed an old challenge card')
    h.begin_round
    emit(presenter, h)
    assert_equal([], names, 'Ready/begin played decorative sounds')
    h.finish_private
    emit(presenter, h)
    assert_equal([], names, 'Committed/revealed attempts replayed private sounds')
    id = h.replay.state[:last_resolution][:id]
    assert_equal(1, id)
  end

  def frozen_turns
    [:player, :observer, :disabled, :covered].each do |mode|
      h = HARNESS.new(options: {'laps' => 2})
      h.start(seed: h.seed_for('guided_missile'))
      presenter = build_presenter(h, viewer: mode == :observer ? 'Watcher' : 'Alice')
      emit(presenter, h)
      @program.gain = 0.3
      @program.enabled = mode != :disabled
      @covered = mode == :covered
      @program.class.settings = {'background_game_sounds' => 'all'} if @covered
      before, first = h.replay, h.events.length
      play_card(h, 'guided_missile')
      assert_equal(1, h.replay.history.count { |entry| entry.kind == :frozen })
      assert(h.replay.state[:race][:racers][0][:frozen_turns].positive?)
      (first...h.events.length).each do |index|
        emit(presenter, h, h.game.replay(h.session, h.events.take(index), h.repository))
        assert_equal([], names, 'An incomplete freeze action played its sound')
      end
      emit(presenter, h)
      assert_equal(mode == :disabled ? 0 : 1, names.count('duck_frozen'))
      3.times { emit(presenter, h) }
      emit(presenter, h, before)
      # No roll is needed: a freeze caused before rolling consumes this turn.
      h.accept({'action' => 'race', 'input' => {'kind' => 'skip'}}, actor: 'Alice')
      skipped = h.replay.history.find { |entry| entry.kind == :skipped }
      assert_equal(true, skipped.value, 'The accepted history lost the reason for skipping')
      emit(presenter, h)
      @program.now_ms = 2_000
      presenter.event_presentation.advance
      assert_equal(mode == :disabled ? 0 : 2, names.count('duck_frozen'), 'Frozen skip did not get its own cue')
      assert_equal(0, names.count('skip'), 'Frozen turn played both ordinary and frozen cues')
      assert(@program.events.all? { |event| event[:volume] == (mode == :covered ? 0.0 : 0.3) })
      @covered = false
      @output.tick
      3.times do
        h.game.turn_text(h.replay)
        emit(presenter, h)
      end
      assert_equal(mode == :disabled ? 0 : 2, names.count('duck_frozen'), 'Status or refresh repeated freezing')
      assert(@program.sounds.all? { |sound| sound.volume.zero? }) if mode == :covered
      @output.close
      @program.class.settings = {}
      cold = build_presenter(h, viewer: 'Watcher')
      emit(cold, h)
      assert_equal([], names, 'Joining replayed historical freezing or skipped turns')
      @output.close
    end
  end

  def sound_policy
    h = HARNESS.new
    h.start(seed: h.seed_for('good_draw'))
    presenter = build_presenter(h)
    emit(presenter, h)
    @program.gain = 0.25
    play_card(h, 'good_draw')
    emit(presenter, h)
    assert_equal(%w[play draw], names)
    assert(@program.events.all? { |event| event[:volume] == 0.25 }, 'Race cues ignored game volume')
    @program.enabled = false
    h.accept({'action' => 'race', 'input' => {'kind' => 'roll'}}, actor: 'Alice')
    emit(presenter, h)
    assert_equal(%w[play draw], names, 'Disabled game sounds were played')
    @output.close

    h = HARNESS.new
    h.start(seed: h.seed_for('good_draw'))
    presenter = build_presenter(h)
    emit(presenter, h)
    @covered = true
    @program.class.settings = {'background_game_sounds' => 'all', 'background_turn_sound' => false}
    play_card(h, 'good_draw')
    emit(presenter, h)
    assert_equal(%w[play draw], names)
    assert(@program.events.all? { |event| event[:volume].zero? }, 'Covered sounds started audible')
    @covered = false
    @output.tick
    emit(presenter, h)
    assert_equal(%w[play draw], names)
    assert(@program.sounds.all? { |sound| sound.volume.zero? }, 'Muted one-shots became audible on return')
  end

  def duel_sounds
    h, presenter = public_challenge('dice_duel')
    assert_equal([], names)
    selection, actor = accept_challenge_input(h, presenter, 'roll')
    assert_equal(['roll'], names)
    assert_equal(:invalid, h.plan(selection, actor: actor).first, 'A repeated roll was accepted')
    3.times { emit(presenter, h) }
    assert_equal(['roll'], names, 'A repeated input or refresh repeated a roll')
    round = h.replay.state[:round]
    h.accept({'action' => 'advance', 'challenge' => round[:challenge][:id]},
      author: h.owner, at: round[:started_at] + 10_100)
    emit(presenter, h)
    assert_equal(%w[roll roll], names, 'The accepted deadline roll was silent')
    assert(h.replay.state[:last_resolution], 'The two accepted rolls did not settle')
    3.times { emit(presenter, h) }
    assert_equal(%w[roll roll], names)
  end

  def risky_dice_sounds
    h, presenter = public_challenge('risky_dice')
    round = h.replay.state[:round]
    actor = h.players.fetch(ENGINE.current_turn(round[:engine]))
    assert_equal(:invalid, h.plan({'action' => 'input', 'challenge' => round[:challenge][:id],
      'input' => {'kind' => 'hit', 'press_id' => 1}}, actor: actor).first)
    emit(presenter, h)
    assert_equal([], names, 'Invalid action played a sound')
    2.times do
      assert_equal(actor, h.players.fetch(ENGINE.current_turn(h.replay.state[:round][:engine])),
        'The fixture must keep the same player below the limit for two rolls')
      accept_challenge_input(h, presenter, 'roll')
    end
    assert_equal(%w[roll roll], names)
    accept_challenge_input(h, presenter, 'save')
    3.times { emit(presenter, h) }
    assert_equal(%w[roll roll], names, 'Save or refresh repeated dice')
    assert(h.replay.state[:round][:engine][:model][:players][h.players.index(actor)][:done])
  end

  def blackjack_sounds
    h, presenter = public_challenge('blackjack')
    assert_equal(['draw'], names, 'Initial cards were silent or played twice')
    3.times { emit(presenter, h) }
    assert_equal(['draw'], names)
    _selection, actor = accept_challenge_input(h, presenter, 'hit')
    assert_equal(%w[draw draw], names)
    # Stand belongs to the current player; a bust already ends that hand.
    selection, standing_actor = accept_challenge_input(h, presenter, 'stand')
    assert_equal(%w[draw draw draw], names, 'The next player should now hear their initial deal')
    assert_equal(:invalid, h.plan(selection.merge('input' => {'kind' => 'hit',
      'press_id' => selection.fetch('input').fetch('press_id') + 1}), actor: standing_actor).first)
    3.times { emit(presenter, h) }
    assert_equal(%w[draw draw draw], names, 'An already finished hand drew a card')
    assert(h.replay.history.any? { |entry| entry.kind == :challenge_draw && entry.text.include?(actor) })
    @output.close
    h, presenter = public_challenge('blackjack', session_id: 92)
    assert_equal(['draw'], names, 'A new accepted hand was mistaken for the old one')
    3.times { emit(presenter, h) }
    assert_equal(['draw'], names)
  end

  def local_policy
    h, presenter = public_challenge('risky_dice')
    @program.gain = 0.3
    accept_challenge_input(h, presenter, 'roll')
    assert_equal(0.3, @program.events.last[:volume])
    @program.enabled = false
    accept_challenge_input(h, presenter, 'roll')
    assert_equal(['roll'], names, 'Disabled public roll remained audible')
    @output.close

    h, presenter = public_challenge('dice_duel', viewer: 'Watcher')
    @program.class.settings = {'background_game_sounds' => 'all', 'background_turn_sound' => false}
    @covered = true
    round = h.replay.state[:round]
    h.accept({'action' => 'advance', 'challenge' => round[:challenge][:id]},
      author: h.owner, at: round[:started_at] + 10_000)
    emit(presenter, h)
    assert_equal(['roll'], names)
    assert_equal(0.0, @program.events.last[:volume])
    @covered = false
    @output.tick
    emit(presenter, h)
    assert_equal(['roll'], names, 'Returning replayed the accepted deadline roll')
    assert_equal(0.0, @program.sounds.last.volume)
    @program.class.settings = {}
    accept_challenge_input(h, presenter, 'roll')
    assert_equal(%w[roll roll], names, 'An observer did not hear an accepted public roll')
    assert_equal(@program.gain, @program.events.last[:volume])
    @output.close

    %w[dice_duel risky_dice blackjack].each do |kind|
      setup_client(kind, viewer: 'Charlie')
      advance(31_000)
      assert_equal([], names, "The observer's local client invented an unaccepted result in #{kind}")
      assert_equal(nil, @client.instance_variable_get(:@trace))
      close
    end
  end

  def public_challenge(kind, viewer: 'Alice', session_id: 91)
    harness = HARNESS.new(kind: kind, session_id: session_id)
    harness.open_round
    presenter = build_presenter(harness, viewer: viewer)
    emit(presenter, harness)
    assert_equal([], names, 'Opening the existing challenge replayed an old card')
    harness.begin_round
    emit(presenter, harness)
    [harness, presenter]
  end

  def accept_challenge_input(harness, presenter, kind)
    round = harness.replay.state[:round]
    seat = ENGINE.current_turn(round[:engine])
    actor = harness.players.fetch(seat)
    selection = {'action' => 'input', 'challenge' => round[:challenge][:id],
      'input' => {'kind' => kind, 'press_id' => round[:engine][:last_press].fetch(seat) + 1}}
    harness.accept(selection, actor: actor)
    emit(presenter, harness)
    [selection, actor]
  end

  def listening_challenges
    %w[count_ducks rhythm sound_order simon sound_memory hit_duck].each do |kind|
      setup_client(kind)
      advance(100)
      @surface.push(:roll)
      @surface.push(:hit)
      advance(200)
      replace
      assert((names & %w[roll draw play shuffle card-shuffle skip]).empty?, "Decorative effects interrupted #{kind}")
      close
    end
  end
end

DuckSoundsTest.new.run
