require_relative "../../support/categories"

%w[pl en].each do |language|
  game = GameRoomGames::Categories.new
  repo = CategoriesRepository.new(%w[Alice Bob])
  session = {'options' => JSON.generate(game.new_game_options('answer_language' => language, 'round_time' => 10))}
  random = Object.new
  def random.roll(count:, sides:); Struct.new(:values).new(Array.new(count, 1)); end
  context = GameRoomGames::ActionContext.new(random_source: random, now: 100, hidden_submissions: nil)
  events, letters = [], []
  alphabet = GameRoomGames::Categories::LANGUAGE_LETTERS.fetch(language)
  (alphabet.length * 2 + 2).times do |index|
    replay = game.replay(session, events, repo)
    context.now = [context.now, replay.state[:resume_at].to_i].max
    action = game.automatic_action(replay, 'Alice', context: context)
    status, plan = game.action_for(action, replay, 'Alice', context: context)
    assert(status == :ok, 'Start failed')
    append_plan(events, plan, 'Alice', now: context.now)
    replay = game.replay(session, events, repo)
    letters << replay.state[:letter]
    assert(replay.state[:used_letters] == alphabet.first(index % alphabet.length + 1), 'Cycle was not reset on acceptance')
    context.now = replay.state[:deadline] + 3
    2.times do
      action = game.automatic_action(replay, 'Alice', context: context)
      status, plan = game.action_for(action, replay, 'Alice', context: context)
      assert(status == :ok, 'Timed phase transition failed')
      append_plan(events, plan, 'Alice', now: context.now)
      replay = game.replay(session, events, repo)
    end
    if [alphabet.length - 1, alphabet.length].include?(index)
      status, plan = game.action_for({'kind'=>'command', 'action'=>'cancel_round'}, replay, 'Alice', context: context)
      assert(status == :ok, 'Cancellation failed at cycle boundary')
      append_plan(events, plan, 'Alice', now: context.now)
      next
    end
    judge = replay.state[:judge]
    status, plan = game.action_for({'kind'=>'review', 'action'=>'finish', 'decisions'=>{}}, replay, judge, context: context)
    assert(status == :ok, 'Empty review failed')
    append_plan(events, plan, judge, now: context.now)
    replay = game.replay(session, events, repo)
    status, plan = game.action_for(game.automatic_action(replay, 'Alice', context: context), replay, 'Alice', context: context)
    assert(status == :ok, 'Scoring failed')
    append_plan(events, plan, 'Alice', now: context.now)
  end
  assert(letters == alphabet * 2 + alphabet.first(2), 'Repeated letter within a cycle')
  assert(game.replay(session, events, repo).accepted_events.length == events.length, 'History lost accepted events')
end
puts 'PASS PL/EN: two complete letter cycles, third-cycle prefix and cancellation on both sides of the boundary'
