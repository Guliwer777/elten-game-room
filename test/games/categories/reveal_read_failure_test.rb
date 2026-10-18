require_relative '../../support/session_runner'
require_relative '../../support/hidden_submission_files'

class CategoriesLockedAnswerStorage < HiddenSubmissionFiles::Storage
  attr_accessor :unreadable
  attr_reader :reads

  def initialize(program)
    super
    @reads = 0
  end

  private

  def read_snapshot_file(path)
    @reads += 1
    raise Errno::EACCES, 'temporary private answer read lock' if unreadable
    super
  end
end

class CategoriesReadFailureFixture
  attr_reader :h, :game, :contexts, :storage, :runners

  def initialize(directory)
    @game = GameRoomGames::Categories.new
    options = game.default_options.merge('round_time' => 0, 'round_category_count' => 1)
    @h = NativeRoomHarness.new(game: game, users: %w[Alice Bob Carol], options: options)
    h.start
    @contexts = h.users.to_h do |user|
      [user, GameRoomGames::ActionContext.new(session_id: h.session['__id'], table_id: h.table['__id'],
        now: Time.now.to_i, table_owner: 'Alice', random_source: GameRoomRandom::SeededSource.new(19),
        hidden_submissions: HiddenSubmissions::Vault.new(HiddenSubmissions::MemoryStorage.new))]
    end
    @storage = CategoriesLockedAnswerStorage.new(HiddenSubmissionFiles.new(directory))
    contexts.fetch('Bob').hidden_submissions = HiddenSubmissions::Vault.new(storage)
    @runners = {}
    h.submit('Alice', context: contexts.fetch('Alice'))
    h.replay('Alice').state[:active_players].each do |user|
      answers = h.replay(user).state[:round_categories].to_h { |category| [category, "#{user} answer"] }
      h.submit(user, {'kind' => 'answer_sheet', 'action' => 'submit', 'answers' => answers}, context: contexts.fetch(user))
    end
    h.submit('Alice', context: contexts.fetch('Alice'))
    h.submit('Carol', context: contexts.fetch('Carol'))
    assert(h.replay('Alice').state[:phase] == :revealing, 'Fixture did not reach revealing')
    storage.unreadable = true
  end

  def runner(user)
    runners[user] ||= runner_for(h, user).tap do |instance|
      instance.instance_variable_get(:@context_template).hidden_submissions = contexts.fetch(user).hidden_submissions
    end
  end

  def tick(user, count: 1); step(h, runner(user), user, count: count); end
  def close; runners.each_value(&:close); end

  def command(action)
    actor = 'Alice'
    h.as(actor) do
      snapshot = h.repositories.fetch(actor).snapshot_for(h.session)
      replay = game.replay(snapshot.session, snapshot.events, h.repositories.fetch(actor))
      result = runner(actor).submit(session: snapshot.session, replay: replay,
        selection: {'kind' => 'command', 'action' => action}, actor: actor)
      assert(result.first == :ok, "Moderator command #{action} failed: #{result.first}")
    end
  end
end

Dir.mktmpdir('categories-read-recover-') do |dir|
  fixture = CategoriesReadFailureFixture.new(dir)
  begin
    before = fixture.h.events('Bob').size
    fixture.tick('Bob')
    assert(!fixture.runner('Bob').instance_variable_get(:@internal_error), 'A read failure permanently stopped the answerer')
    assert(fixture.h.events('Bob').size == before, 'An unreadable answer was published')
    assert(fixture.runner('Bob').instance_variable_get(:@automatic_retry_key), 'The recoverable read did not use existing backoff')
    reads = fixture.storage.reads
    fixture.tick('Bob', count: 20)
    assert(fixture.storage.reads == reads, 'Unavailable storage was polled on every tick')
    fixture.storage.unreadable = false
    fixture.tick('Bob')
    assert(fixture.h.events('Bob').size == before, 'Recovery bypassed the existing retry delay')
    sleep 1.05
    fixture.tick('Bob', count: 3)
    state = fixture.h.replay('Bob').state
    assert(state[:reveals].keys.sort == %w[Bob Carol], 'The recovered private sheet was not revealed')
    fixture.tick('Alice', count: 3)
    assert(fixture.h.replay('Alice').state[:phase] == :review, 'Recovery did not allow the normal review')
    accepted = fixture.h.events('Bob').size
    fixture.h.broker.deliver(duplicate: true)
    fixture.tick('Bob', count: 4)
    assert(fixture.h.events('Bob').size == accepted, 'Recovery duplicated the reveal')
    fixture.h.assert_converged('Categories read failure recovery')
  ensure
    fixture.close
  end
end

%w[cancel_round start_review].each do |command|
  Dir.mktmpdir("categories-read-#{command}-") do |dir|
    fixture = CategoriesReadFailureFixture.new(dir)
    begin
      fixture.tick('Bob')
      fixture.command(command)
      fixture.tick('Bob', count: 3)
      current = fixture.h.replay('Alice')
      expected = command == 'cancel_round' ? :round_complete : :review
      assert(current.state[:phase] == expected, 'An unreadable private file blocked the moderator')
      assert(!fixture.runner('Bob').instance_variable_get(:@internal_error), 'An old read error survived moderation')
      assert(current.state[:scores].values.all?(&:zero?), 'Missing private data fabricated points')
      after_moderation = fixture.h.events('Bob').size
      fixture.storage.unreadable = false
      fixture.tick('Bob', count: 4)
      assert(fixture.h.events('Bob').size == after_moderation, 'A late recovered envelope escaped the closed reveal phase')
      fixture.h.assert_converged("Categories unreadable answer and #{command}")
    ensure
      fixture.close
    end
  end
end

Dir.mktmpdir('categories-read-missing-') do |dir|
  fixture = CategoriesReadFailureFixture.new(dir)
  begin
    fixture.tick('Bob')
    before = fixture.h.events('Bob').size
    fixture.storage.unreadable = false
    state = fixture.h.replay('Bob').state
    fixture.contexts.fetch('Bob').hidden_submissions.discard(
      session_id: fixture.h.session['__id'], round_id: fixture.game.send(:round_id, state), user: 'Bob')
    fixture.runner('Bob').instance_variable_set(:@automatic_retry_at, 0.0)
    fixture.tick('Bob')
    reads = fixture.storage.reads
    fixture.tick('Bob', count: 20)
    assert(fixture.storage.reads == reads, 'A successful read of a missing sheet kept polling on every tick')
    assert(fixture.h.events('Bob').size == before, 'A missing private sheet fabricated an answer')
    assert(fixture.runner('Bob').instance_variable_get(:@automatic_retry_key).nil?, 'An empty retry stayed pending')
    fixture.command('cancel_round')
    assert(fixture.h.replay('Alice').state[:phase] == :round_complete, 'A missing sheet prevented cancellation')
  ensure
    fixture.close
  end
end

puts 'PASS Categories unreadable private sheet: native runner retry, recovery, cancellation, review without missing answers and no stale reveal'
