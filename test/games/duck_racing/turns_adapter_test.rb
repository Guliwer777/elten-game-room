require_relative '../../support/duck_game_adapter'
require_relative '../../../lib/game_event_presenter'
include DuckGameAdapterTest

cases = 0
case_filter = Regexp.new(ENV.fetch('DUCK_TURNS_CASE')) if ENV.key?('DUCK_TURNS_CASE')
%w[dice_duel blackjack risky_dice].each do |kind|
  [2, 3, 8].each do |count|
    next if case_filter && !case_filter.match?("#{kind}/#{count}")

    h = Harness.new(kind: kind, count: count)
    h.open_round
    h.begin_round
    initial_model = h.replay.state[:round][:engine][:model]
    attempt_order = initial_model[:participants].rotate(initial_model[:turn_index]).reject { |seat| initial_model[:players].fetch(seat)[:done] }
    presses = Hash.new(0)
    memories = Hash.new { |hash, seat| hash[seat] = {} }
    steps = 0
    actors = []
    turn_sounds = h.players.to_h { |actor| [actor, []] }
    presenters = h.players.to_h do |actor|
      program = Object.new
      program.define_singleton_method(:play_sound_from_asset) { |name, **_options| turn_sounds.fetch(actor) << name }
      [actor, GameRoomEventPresenter.new(game: -> { h.game }, repository: -> { h.repository },
        program: -> { program }, viewer: -> { actor }, client: -> { nil }, surface_state: -> { {} },
        clock: -> { h.now_ms / 1_000.0 }, covered: -> { true }, speech: ->(*) {}, trace: ->(*) {},
        history_changed: ->(*) {}, session_changed: -> {})]
    end
    presenters.each_value { |presenter| presenter.send(:present_required_decision, nil, h.replay) }
    while (round = h.replay.state[:round])
      before = h.replay
      engine = round.fetch(:engine)
      seat = LOGIC::ChallengeEngine.current_turn(engine)
      actor = h.players.fetch(seat)
      view = LOGIC::ChallengeEngine.view(engine, seat: seat)
      choice = LOGIC::ChallengeBot.choose_sequential(view, seat: seat, seed: count,
        memory: memories[seat], press_id: presses[seat] + 1)
      assert(choice, "#{kind}: active actor has no legal choice")
      input = choice.fetch(:action)
      selection = {'action' => 'input', 'challenge' => round[:challenge][:id], 'input' => input}
      at = h.now_ms + choice.fetch(:delay_ms)
      other = h.players.fetch((seat + 1) % count)
      assert(h.plan(selection, actor: other, at: at).first != :ok, "#{kind}: other player acted out of turn")
      decision = h.game.required_decision_key(before, actor)
      assert_equal(nil, h.game.required_decision_key(before, other))
      if %w[blackjack risky_dice].include?(kind)
        assert_equal([round[:challenge][:id], seat], decision,
          "#{kind}: decision must identify the whole attempt, not a single action")
      end
      h.accept(selection, actor: actor, at: at)
      after = h.replay
      history = after.history.drop(before.history.length)
      expected = case input.fetch(:kind).to_s
      when 'roll' then [:challenge_roll, 'roll']
      when 'hit' then [:challenge_draw, 'draw']
      when 'stand', 'save' then [:challenge_stand, nil]
      else raise "Unexpected input #{input.inspect}"
      end
      movements = history.select { |entry| %i[challenge_roll challenge_draw challenge_stand].include?(entry.kind) }
      assert_equal(1, movements.length, "#{kind}: missing or repeated public action")
      assert_equal(expected.first, movements.first.kind)
      assert(movements.first.text.include?(actor), "#{kind}: public action lost its player")
      assert(movements.first.text.end_with?('.'), "#{kind}: public action lacks punctuation")
      cues = h.game.event_sound_cues(event: h.events.last, before_replay: before, after_replay: after,
        history: history, viewer: other, random_variant: 0)
      expected_cues = [expected.last].compact
      expected_cues << 'draw' if history.any? { |entry| entry.kind == :challenge_hand }
      assert_equal(expected_cues.uniq, cues, "#{kind}: opponent did not receive normal action audio")
      assert_equal(DuckGameAdapterTest.semantic(after), DuckGameAdapterTest.semantic(h.replay))
      if after.state[:round]
        presenters.each_value { |presenter| presenter.send(:present_required_decision, before, after) }
        if %w[blackjack risky_dice].include?(kind) && LOGIC::ChallengeEngine.current_turn(after.state[:round][:engine]) == seat
          assert_equal(decision, h.game.required_decision_key(after, actor),
            "#{kind}: another action restarted the same decision")
          assert_equal(1, turn_sounds.fetch(actor).count('ding'), 'Another action repeated the own-turn signal')
        else
          assert(decision != h.game.required_decision_key(after, actor),
            "#{kind}: executor retained an old turn decision")
        end
      end
      actors << seat
      memories[seat], presses[seat] = choice[:memory], presses[seat] + 1
      steps += 1
      assert(steps < 150, "#{kind}: sequential challenge stalled")
    end
    assert_equal(kind, h.replay.state[:last_resolution][:kind])
    assert_equal(:turn, h.replay.state[:race][:phase])
    assert(h.decode.none? { |data, _actor, _events| %w[commit reveal].include?(data['action']) })
    if %w[blackjack risky_dice].include?(kind)
      order = actors.chunk(&:itself).map(&:first)
      assert_equal(attempt_order, order, "#{kind}: attempts were interleaved or a completed player returned")
      h.players.each do |actor|
        expected_sounds = order.include?(h.players.index(actor)) ? ['ding'] : []
        assert_equal(expected_sounds, turn_sounds.fetch(actor), "#{actor}: expected one signal for the whole attempt")
      end
    end
    cases += 1
  end
end

if !case_filter || case_filter.match?('race command')
  h = Harness.new
  h.start
  before = h.replay
  h.players.each_with_index do |actor, seat|
    spec = h.game.surface_spec(before, actor)
    assert_equal(1, spec.parts.length, 'Race still has a separate Roll panel')
    hand = spec.parts.first.surface.zones.first
    assert_equal(3, hand.cards.length, 'Roll became a fake card')
    commands = Array(hand.commands)
    assert_equal(1, commands.length, 'The stable roll row disappeared outside the active turn')
    if seat.zero?
      assert_equal('Roll the die', commands.first.label)
      h.accept({'kind' => 'command', 'action' => commands.first.id}.merge(commands.first.payload.to_h), actor: actor)
    end
  end
  assert(h.replay.history.any? { |entry| entry.kind == :rolled }, 'The card-list Roll command was not accepted')
end
raise "No turn adapter cases matched #{case_filter.inspect}" if cases.zero? && case_filter && !case_filter.match?('race command')
puts "PASS #{cases} sequential Duck adapter scenarios (2/3/8 players), public history/audio and revisions#{case_filter ? ", filter #{case_filter.source}" : ', and race command'}"
