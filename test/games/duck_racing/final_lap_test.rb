# frozen_string_literal: true

require_relative '../../support/duck_game_adapter'
require_relative '../../support/localization'
require_relative 'challenge_audio_helpers'
require_relative '../../../lib/game_event_presenter'

include DuckGameAdapterTest

h = Harness.new
game = h.game

def transition(h, progress:, action:, laps: 3, target: 0)
  before = h.start
  race = before.state[:race]
  race[:laps] = laps
  race[:occupants] = {}
  race[:racers].each do |seat, racer|
    racer[:progress] = seat == target ? progress : 3
    LOGIC::Board.arrive!(race[:occupants], seat, LOGIC::Board.square(racer[:progress]))
  end
  after = Marshal.load(Marshal.dump(before))
  state = after.state[:race]
  if action.is_a?(String)
    state[:racers][0][:hand] << LOGIC::Cards::Copy.new('lap-test', action)
    input = {kind: :play, card: 'lap-test', target: target}
  else
    state[:racers][0][:die_sides] = 1
    state[:racers][0][:die_rolls] = 2
    input = {kind: :roll}
  end
  assert(LOGIC::Race.new(state).apply(seat: 0, revision: state[:revision], action: input))
  event = {'__id' => 999, 'id' => 999, 'actor' => 'Alice'}
  after.accepted_events = before.accepted_events + [event]
  h.game.send(:append_notices, after.history, state[:notices], 999, after.players)
  [before, after, event]
end

# Real reducer paths: a roll, self/other card moves and backwards movement.
[
  [59, :roll, 3, 0, 1], [59, 'impulsion', 3, 0, 1],
  [59, 'impulsion', 3, 1, 1], [58, :roll, 3, 0, 0],
  [60, :roll, 3, 0, 0], [60, 'withdrawal', 3, 0, 0],
  [29, :roll, 3, 0, 0], [89, :roll, 3, 0, 0],
  [0, :roll, 1, 0, 0], [29, :roll, 1, 0, 0]
].each do |progress, action, laps, target, expected|
  h = Harness.new
  before, after, event = transition(h, progress: progress, action: action, laps: laps, target: target)
  entries = after.history.select { |entry| entry.event_id == 999 }
  assert_equal(expected, entries.count { |entry| entry.kind == :final_lap })
  if expected == 1
    assert_equal("#{after.players[target]} begins the final lap.", entries.find { |entry| entry.kind == :final_lap }.text)
    assert(entries.none? { |entry| entry.kind == :moved && entry.text.include?('begins lap') }, 'Lap announced twice')
  end
  %w[Alice Bob Watcher].each do |viewer|
    cues = game.event_sound_cues(event: event, before_replay: before, after_replay: after,
      history: entries, viewer: viewer, random_variant: ->(*_args) { 0 })
    assert_equal(expected, cues.count('duck_final_lap'))
  end
end

# Existing presenter owns notification delivery: snapshots and identical
# refreshes must never replay the final-lap sound. No separate timer/poller.
h = Harness.new
before, after, event = transition(h, progress: 59, action: :roll)
[false, true].each do |covered|
  [false, true].each do |muted|
    %w[Alice Bob Watcher].each do |viewer|
      program = DuckChallengeAudioTest::Program.new
      program.enabled = !muted
      spoken = []
      presenter = GameRoomEventPresenter.new(game: -> { game }, repository: -> { h.repository },
        program: -> { program }, viewer: -> { viewer }, client: -> { nil }, surface_state: -> { {} },
        clock: -> { program.now_ms / 1000.0 }, covered: -> { covered },
        speech: ->(text) { spoken << text }, trace: ->(*_args, **_options) {},
        history_changed: ->(*_args) {}, session_changed: -> {})
      presenter.define_singleton_method(:event_replays_for) do |_replay, events, session:|
        events.to_h { |item| [item['id'], [before, after]] }
      end
      presenter.process_new_events(before, session: h.session)
      spoken.clear
      program.events.clear
      presenter.process_new_events(after, session: h.session)
      5.times do
        program.now_ms += 1_000
        presenter.event_presentation.advance
        presenter.process_new_events(after, session: h.session)
      end
      assert_equal(1, spoken.count('Alice begins the final lap.'))
      assert_equal(muted ? 0 : 1, program.events.count { |item| item[:asset] == 'duck_final_lap' })
      presenter.event_presentation.close
    end
  end
end

{
  'en' => 'Alice begins the final lap.',
  'pl' => 'Alice rozpoczyna finałowe okrążenie.',
  'cs' => 'Alice začíná poslední kolo.',
  'es' => 'Alice empieza la última vuelta.',
  'ru' => 'Alice начинает последний круг.'
}.each do |language, expected|
  GameRoomTestLocalization.use_language(language)
  history = []
  game.send(:append_notices, history, [[:final_lap, 0]], 900, %w[Alice Bob])
  assert_equal(expected, history.first.text)
end
GameRoomTestLocalization.use_language('en')

# Summary/discovery carries the question language, not the creator's UI
# language or a guessed language when the old payload omits that option.
LOGIC::QuestionSets.languages(registry: game.content_registry).each do |language|
  options = game.normalize_options('question_language' => language)
  label = game.content_registry.language(language).label
  summary = game.options_summary(options)
  assert_equal("3 laps, #{label}", summary)
  assert_equal(summary, game.notification_variant(options))
  assert(game.notification_option_keys(options).include?('question_language'))
end
assert_equal('3 laps', game.options_summary('laps' => 3))
assert_equal('', game.options_summary({}))
puts 'PASS final lap: reducer roll/cards/backwards/finish, per-player sound and deduplication, mute, five languages and table summaries'
