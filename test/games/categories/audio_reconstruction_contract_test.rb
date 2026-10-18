require_relative '../../support/ui'
require_relative '../../support/categories'
require_relative '../../support/sequence_random'
require_relative '../../../lib/game_event_presenter'

game = GameRoomGames::Categories.new
repository = CategoriesRepository.new(%w[Alice Bob])
session = {'id' => 901, 'options' => JSON.generate(game.default_options.merge('round_time' => 30))}
context = GameRoomGames::ActionContext.new(session_id: 901, table_id: 902, now: 100,
  hidden_submissions: HiddenSubmissions::Vault.new(HiddenSubmissions::MemoryStorage.new),
  random_source: GameRoomRandom::SequenceSource.new([1]))
events = []
initial = game.replay(session, events, repository)
status, plan = game.action_for(game.automatic_action(initial, 'Alice', context: context), initial, 'Alice', context: context)
assert(status == :ok, 'Round setup failed')
append_plan(events, plan, 'Alice', now: 100)
answering = game.replay(session, events, repository)

make_presenter = lambda do
  sounds, speech = [], []
  program = Object.new
  program.define_singleton_method(:play_sound_from_asset) { |name, **_options| sounds << name }
  presenter = GameRoomEventPresenter.new(game: -> { game }, repository: -> { repository },
    program: -> { program }, viewer: -> { 'Alice' }, client: -> { nil },
    surface_state: -> { {} }, clock: -> { 0 }, covered: -> { false },
    speech: ->(text) { speech << text }, trace: ->(*) {}, history_changed: ->(*) {}, session_changed: -> {})
  [presenter, sounds, speech]
end

presenter, sounds, speech = make_presenter.call
presenter.process_new_events(answering, session: session, timer_now: 100)
sounds.clear
speech.clear
presenter.announce_due_timers(answering, now: 109)
assert(sounds.empty?, 'The warning played with more than 20 seconds remaining')
3.times { presenter.announce_due_timers(answering, now: 110) }
presenter.announce_due_timers(answering, now: 129)
assert(sounds == ['buzzer2'] && speech.count('20 seconds remain.') == 1,
  'The 20-second warning was silent, repeated or used the expiry cue')
3.times { presenter.announce_due_timers(answering, now: 130) }
assert(sounds == ['buzzer2', 'buzzer'] && speech.count('Time is up.') == 1, 'A normal deadline did not produce exactly one expiry cue')
presenter.process_new_events(answering, session: session, timer_now: 131)
presenter.announce_due_timers(answering, now: 131)
assert(sounds == ['buzzer2', 'buzzer'], 'An unchanged replay repeated expiry')

late, late_sounds, late_speech = make_presenter.call
late.process_new_events(answering, session: session, timer_now: 115)
late_sounds.clear
late_speech.clear
2.times { late.announce_due_timers(answering, now: 116) }
assert(late_sounds.empty? && late_speech.empty?, 'Joining with less than 20 seconds left replayed the old warning')
late.announce_due_timers(answering, now: 130)
assert(late_sounds == ['buzzer'], 'Suppressing the historical warning also suppressed the later live expiry')

rejoined, rejoined_sounds, rejoined_speech = make_presenter.call
rejoined.process_new_events(answering, session: session, timer_now: 131)
rejoined_sounds.clear
rejoined_speech.clear
2.times { rejoined.announce_due_timers(answering, now: 131) }
assert(rejoined_sounds.empty? && rejoined_speech.empty?, 'Reconstructing an already expired question replayed its expiry cue')

submission_presenter, submitted_sounds, = make_presenter.call
submission_presenter.process_new_events(answering, session: session, timer_now: 100)
submitted_sounds.clear
status, plan = game.action_for(surface_action('answer_sheet', 'submit', 'answers' => {'country' => 'Austria'}),
  answering, 'Bob', context: context)
assert(status == :ok, 'A live answer fixture was rejected')
append_plan(events, plan, 'Bob', now: 105)
submitted = game.replay(session, events, repository)
2.times { submission_presenter.process_new_events(submitted, session: session, timer_now: 105) }
assert(submitted_sounds.count('play') == 1, 'Accepted answer submission was silent or sounded twice')
assert(events.last['action'] == 'answer_commit' && !events.last['value'].include?('Austria'),
  'A submission sound introduced a public answer leak')

events << events.last.merge('id' => events.length + 1, 'created_at' => 106)
duplicate = game.replay(session, events, repository)
assert(duplicate.accepted_events.length == submitted.accepted_events.length, 'Duplicate answer fixture was unexpectedly accepted')
submission_presenter.process_new_events(duplicate, session: session, timer_now: 106)
assert(submitted_sounds.count('play') == 1, 'A rejected duplicate emitted a submission sound')

historical, historical_sounds, = make_presenter.call
historical.process_new_events(submitted, session: session, timer_now: 106)
assert(!historical_sounds.include?('play'), 'Opening an existing round replayed an old submission sound')

puts 'PASS Categories: 20-second warning and expiry once, reconstruction suppresses old cues, accepted submission once, duplicate rejected and historical submission silent'
