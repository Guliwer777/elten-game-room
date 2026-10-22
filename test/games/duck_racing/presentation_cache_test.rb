require 'fileutils'
require_relative '../../support/duck_game_adapter'
require_relative 'client_helpers'
require_relative '../../../lib/game_event_presenter'
require_relative '../../../games/uno'
require_relative '../../../games/ninety_nine'
require_relative '../../../games/axel_pong'
require_relative '../../../games/audio_ball'

# Complete real reducer/presenter, local fixtures only. No host connection.
class DuckPresentationCacheTest
  include DuckGameAdapterTest

  def copy(value); Marshal.load(Marshal.dump(value)); end
  def semantic(value); DuckGameAdapterTest.semantic(value); end

  def presenter(h)
    GameRoomEventPresenter.new(game: -> { h.game }, repository: -> { h.repository },
      program: -> {}, viewer: -> { h.players.first }, client: -> {}, surface_state: -> { {} },
      clock: -> { 0.0 }, covered: -> { false }, speech: ->(*) {}, trace: ->(*, **) {},
      history_changed: ->(*) {}, session_changed: -> {})
  end

  def cold(h, session, events)
    h.game.build_session_game.replay(session, events, h.repository)
  end

  def compare(h, presentation, session, events, fresh)
    final = h.game.replay(session, events, h.repository)
    untouched = semantic(final)
    transitions = presentation.event_replays_for(final, fresh, session: session)
    assert_equal(fresh.length, transitions.length, 'A physical transition was skipped')
    fresh.each do |event|
      index = final.accepted_events.index(event)
      expected = [cold(h, session, final.accepted_events.first(index)),
        cold(h, session, final.accepted_events.first(index + 1))]
      actual = transitions.fetch(h.repository.event_id(event))
      assert_equal(semantic(expected), semantic(actual), "Intermediate state differs at #{event['id']}")
      @comparisons += 1
    end
    assert_equal(untouched, semantic(final), 'Canonical final state was mutated')
    [final, transitions]
  end

  def finished_fixture
    h = Harness.new
    h.open_round
    h.begin_round
    h.finish_private
    h
  end

  def run
    @comparisons, @cases = 0, []
    check('one independent Duck reducer, prepared resources retained, no client copied') do
      h = Harness.new
      h.game.instance_variable_set(:@local_client, :must_not_be_copied)
      prepared = h.game.resources_for(h.replay.state[:options])
      ui = presenter(h)
      cache = ui.presentation_replay
      model = cache.instance_variable_get(:@game)
      assert(!model.equal?(h.game))
      assert(model.resources_for(h.replay.state[:options]).equal?(prepared))
      assert(model.instance_variable_get(:@bot_cache).equal?(h.game.instance_variable_get(:@bot_cache)))
      assert(prepared.frozen?, 'Shared prepared resources must remain immutable')
      model.replay(h.session, h.events, h.repository)
      assert(!model.instance_variable_get(:@duck_replay_cache).equal?(h.game.instance_variable_get(:@duck_replay_cache)))
      assert_equal(nil, model.local_client)
      assert(ui.presentation_replay.equal?(cache), 'Refresh created another presentation reducer')
    end

    check('ordinary games use their existing UI instance') do
      [GameRoomGames::Base, GameRoomGames::Uno, GameRoomGames::NinetyNine,
        GameRoomGames::AxelPong, GameRoomGames::AudioBall].each do |type|
        game = type.new
        assert(game.build_presentation_game.equal?(game), "#{type} did not keep default self")
      end
    end

    check('every private fragment, warm batches, catch-up and mutations of returned states') do
      h = finished_fixture
      [1, 7, h.events.length].each do |size|
        ui = presenter(h)
        previous = h.game.replay(h.session, [], h.repository)
        ui.presentation_replay.remember(h.session, previous)
        prefix = []
        h.events.each_slice(size) do |batch|
          prefix.concat(batch)
          full = h.game.replay(h.session, prefix, h.repository)
          fresh = full.accepted_events.drop(previous.accepted_events.length)
          final, transitions = compare(h, ui, h.session, prefix, fresh)
          # A caller's mutable copies cannot corrupt the next prefix or RNG.
          transitions.values.each do |before, after|
            [before, after].each do |value|
              value.history.clear
              value.state.dig(:race, :racers, 0, :hand)&.clear
              value.state.dig(:race, :random)&.rand
              # Authenticated event records are sealed even in returned
              # snapshots. Mutable presentation fields above remain detached.
              wire_value = value.accepted_events.first&.fetch('value')
              if wire_value
                if wire_value.frozen?
                  assert_raises(FrozenError) { wire_value.replace('caller-only edit') }
                else
                  wire_value.replace('caller-only edit')
                end
              end
            end
          end
          assert_equal(semantic(full), semantic(final))
          assert_equal({}, ui.event_replays_for(final, [], session: h.session))
          previous = final
        end
      end
    end

    check('new session, epoch, owner, clock, options and an edited old record invalidate prefixes') do
      h = finished_fixture
      variants = [h.session.merge('__control_epoch' => 'new'), h.session.merge('__table_owner' => 'Bob'),
        h.session.merge('__clock_offset' => 17, '__frozen_at' => 12345),
        h.session.merge('options' => JSON.generate(h.game.options_from_json(h.session['options']).merge('laps' => 4)))]
      variants.each do |session|
        ui = presenter(h)
        initial = h.game.replay(h.session, h.decode.first.last, h.repository)
        ui.presentation_replay.remember(h.session, initial)
        full = h.game.replay(session, h.events, h.repository)
        compare(h, ui, session, h.events, full.accepted_events.drop(initial.accepted_events.length))
      end
      ui = presenter(h)
      ui.presentation_replay.remember(h.session, h.replay)
      next_game = Harness.new(session_id: 92)
      next_game.start(seed: 91)
      compare(next_game, ui, next_game.session, next_game.events, next_game.replay.accepted_events)

      ui = presenter(h)
      initial = h.game.replay(h.session, h.decode.first.last, h.repository)
      ui.presentation_replay.remember(h.session, initial)
      edited = copy(h.events)
      edited.first['created_at'] += 1
      full = h.game.replay(h.session, edited, h.repository)
      compare(h, ui, h.session, edited, full.accepted_events.drop(initial.accepted_events.length))
    end

    check('changed participant cancels, unrelated changed seat preserves the active duel') do
      [1, 2].each do |seat|
        h = Harness.new(count: 3)
        h.open_round(group: false)
        id = h.begin_round
        ui = presenter(h)
        before = h.replay
        ui.presentation_replay.remember(h.session, before)
        h.replace(seat, 'Replacement')
        current = h.replay
        if seat == 1
          assert_equal(:participant_changed, current.state[:last_resolution][:cancelled])
          h.accept({'action' => 'race', 'input' => {'kind' => 'roll'}}, actor: current.current_player)
        else
          assert_equal(id, current.state[:round][:challenge][:id])
          h.accept({'action' => 'alive', 'challenge' => id}, actor: 'Alice',
            at: current.state[:round][:last_seen].fetch(0) + LOGIC::Session::PULSE_MS)
        end
        full = h.replay
        compare(h, ui, h.session, h.events, full.accepted_events.drop(before.accepted_events.length))
      end
    end

    check('two memory reveals in one refresh reach actual audio once each') { memory_sounds }

    check('historical fragments reuse the isolated authenticated prefix rather than full-reducing it') do
      h = finished_fixture
      final = h.replay
      baseline = GameRoomPresentationReplay.new(h.game, h.repository)
      count = lambda do |&work|
        calls = 0
        tracer = TracePoint.new(:call) { |point| calls += 1 if point.method_id == :apply && point.self.equal?(LOGIC::Session) }
        value = tracer.enable(&work)
        [calls, value]
      end
      full_count, old = count.call { baseline.transitions(h.session, final, final.accepted_events) }
      new_count, fresh = count.call { presenter(h).event_replays_for(final, final.accepted_events, session: h.session) }
      assert_equal(semantic(old), semantic(fresh))
      assert(new_count < full_count, "No reduction in repeated rules: #{new_count}/#{full_count}")
      @reduction = {previous_applications: full_count, isolated_applications: new_count}
    end

    FileUtils.mkdir_p('tmp/duck-racing')
    report = {status: @cases.all? { |item| item[:status] == 'PASS' } ? 'PASS' : 'FAIL', cases: @cases,
      compared_intermediate_states: @comparisons, rule_applications: @reduction,
      scope: 'Local real model/presenter/client with recording audio device; not live UI or physical audio'}
    File.write('tmp/duck-racing/presentation-cache-local.json', JSON.pretty_generate(report) + "\n")
    @cases.each { |item| puts "#{item[:status]} #{item[:name]}#{item[:error] ? ": #{item[:error]}" : ''}" }
    puts "#{@comparisons} complete intermediate state comparisons"
    raise 'Duck presentation cache regression' unless report[:status] == 'PASS'
  end

  def check(name)
    yield
    @cases << {name: name, status: 'PASS'}
  rescue StandardError => error
    @cases << {name: name, status: 'FAIL', error: "#{error.class}: #{error.message}", location: error.backtrace.first(5)}
  end

  def memory_sounds
    h = Harness.new(kind: 'sound_memory')
    h.open_round(group: false)
    id = h.begin_round
    initial = h.replay
    ui = presenter(h)
    ui.presentation_replay.remember(h.session, initial)
    seat = initial.state.dig(:round, :engine, :model, :public, :turn)
    actor = h.players.fetch(seat)
    [1, 2].each do |position|
      h.accept({'action' => 'input', 'challenge' => id,
        'input' => {'kind' => 'reveal', 'value' => position, 'press_id' => position}}, actor: actor)
    end
    final, transitions = compare(h, ui, h.session, h.events,
      h.replay.accepted_events.drop(initial.accepted_events.length))
    program = DuckChallengeAudioTest::Program.new
    client = LOGIC::Client.new(program, h.game, clock: -> { program.now_ms / 1000.0 },
      realtime_factory: -> { DuckClientTest::Realtime.new(program) })
    client.bind_screen(session_id: h.session['__id'], table_id: 41, owner: h.owner, viewer: actor, members: -> { h.players })
    final.accepted_events.drop(initial.accepted_events.length).each do |event|
      before, after = transitions.fetch(h.repository.event_id(event))
      2.times { client.event(event, before, after, actor, h.repository) }
    end
    [0, 200, 400, 600, 800].each { |at| program.now_ms = at; client.tick }
    memory = program.events.select { |event| LOGIC::ChallengeAudio::MEMORY_ASSETS.include?(event[:asset]) }
    assert_equal(2, memory.length, 'First sound was dropped or a repeated fragment replayed it')
    assert_equal(1, program.events.count { |event| %w[replay buzzer].include?(event[:asset]) }, 'Pair feedback was omitted or repeated')
    assert_equal(2, client.instance_variable_get(:@memory_serial))
  ensure
    client&.close
  end
end

DuckPresentationCacheTest.new.run
