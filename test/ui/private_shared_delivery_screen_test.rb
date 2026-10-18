require_relative '../support/duck_challenge_native'
require_relative '../support/private_card_games'
require_relative '../support/native_private_messages'
require_relative '../../games/taboo'
require_relative '../../lib/game_screen'

FormTimer = EltenAPI::Controls::FormTimer unless defined?(FormTimer)

# Real private take + addressed delivery, normal repository/runner, native
# controls and Tasks. No public event follows the held private message.
class SharedDrawScreenFixture
  attr_reader :h, :runners, :screens, :waits, :giver, :recipients, :snapshots, :reads

  def initialize
    DuckChallengeNativeDriver.new
    $currentthread = Thread.current
    @h, @runners = PrivateCardGamesTest.create(GameRoomGames::Taboo.new,
      users: %w[Alice Bob Carol Dave])
    h.add_client('Observer')
    assert(h.join('Observer'), 'Observer could not join')
    h.as('Observer') { h.transports['Observer'].set_observer(h.table, true, actor: 'Observer') }
    @giver = h.replay('Alice').current_player
    h.view(giver).hold_message = true
    play(giver, 'start')
    play(h.core.owner, 'begin', h.replay(giver).state[:deadline])
    5.times { PrivateCardGamesTest.tick(h, runners) }
    @recipients = h.game.private_draw_audiences(h.replay(giver).state).values.first.fetch(:recipients)
    @snapshots, @screens, @waits, @reads = {}, {}, {}, []
    (h.users + ['Observer']).each do |user|
      runners[user] ||= runner_for(h, user, covered: -> { false })
      runners[user].instance_variable_set(:@covered, -> { false })
      step(h, runners[user], user)
      as(user) do
        repo = h.repositories.fetch(user)
        snapshot = snapshots[user] = repo.snapshot_for(h.session)
        replay = h.game.replay(snapshot.session, snapshot.events, repo)
        assert(h.game.card_lines(replay.state, user).empty?, "#{user}: private message was not delayed") if user != giver
        sync = GameRoomSync::Controller.new(transport: h.transports[user],
          table_id: h.table['__id'], session_id: h.session['__id'])
        loop { break unless sync.next_event }
        room = -> { LobbyRepository::TableSnapshot.new(**h.transports[user].room_snapshot(h.table)) }
        screen = screens[user] = GameScreen.new(program: ProgramDouble.new(h.broker.endpoint(user)),
          repository: repo, game: h.game, session: snapshot.session, table: h.table,
          table_owner: h.core.owner, synchronizer: sync, room_snapshot_provider: room,
          game_services: {transport: h.transports[user]})
        screen.instance_variable_set(:@session_runner, runners[user])
        screen.instance_variable_set(:@room_snapshot, room.call)
        layout = screen.send(:prepare_action_view, replay).layout
        layout.form.index = layout.form.fields.index(layout.chat)
        layout.chat.set_text('Unsent private-card test draft')
        layout.chat.restore_selection(index: 5, check: 2)
        screen.send(:remember_layout_position)
        screen.send(:publish_session_view, replay, layout.surface)
        waits[user] = GameScreen::WaitState.new(replay: replay,
          revision: repo.events_revision(snapshot.events), action: :check_signal)
        original = repo.method(:snapshot_for)
        log = reads
        repo.define_singleton_method(:snapshot_for) do |*args, **options|
          log << [user, Thread.current]
          original.call(*args, **options)
        end
      end
    end
  end

  def as(user)
    previous = $game_room_test_user
    $game_room_test_user = user
    h.as(user) { yield }
  ensure
    $game_room_test_user = previous
  end

  def play(user, action, now = nil)
    replay = h.replay(user)
    ctx = GameRoomGames::ActionContext.new(table_owner: h.core.owner,
      now: now || [Time.now.to_i, replay.state[:time]].max)
    h.submit(user, {'action' => action, 'token' => h.game.token(replay.state)}, context: ctx)
  end

  def deliver
    held = h.view(giver).sent_messages.select do |message|
      message.dig(:packet, 'payload', 'type') == 'private_draw_share' &&
        message.dig(:packet, 'payload', 'action') == 'values'
    end
    assert(held.map { |message| message[:recipient] }.sort == recipients.sort,
      'Held private values have an unexpected audience')
    h.view(giver).hold_message = false
    held.each do |message|
      h.view(giver).send_private(message[:recipient], message[:packet], message_id: SecureRandom.uuid)
    end
  end

  def refresh(user)
    as(user) do
      screen, wait = screens.fetch(user), waits.fetch(user)
      old_layout = screen.instance_variable_get(:@layout)
      changed = screen.send(:handle_signal_wait, wait, old_layout)
      return false unless changed
      assert(wait.action == :refresh, 'Private delivery changed the game identity')
      snapshot, room, = screen.send(:fetch_game_payload)
      replay = h.game.replay(snapshot.session, snapshot.events, h.repositories[user])
      screen.instance_variable_set(:@session, snapshot.session)
      screen.instance_variable_set(:@room_snapshot, room)
      layout = screen.send(:prepare_action_view, replay).layout
      assert(layout.equal?(old_layout), 'Private delivery replaced the native layout')
      assert(layout.chat.text == 'Unsent private-card test draft', 'Private delivery erased chat')
      assert(layout.chat.index == 5 && layout.chat.check == 2, 'Private delivery lost chat selection')
      assert(layout.focus_location == [:chat, 0], 'Private delivery stole chat focus')
      assert(layout.surface.fields.first.options == h.game.card_lines(replay.state, user),
        'The actual native card list retained its old empty projection')
      wait.replay = replay
      wait.action = :check_signal
      true
    end
  end

  def close
    screens.each_value { |screen| screen.instance_variable_get(:@layout).form.game_room_pending_operation&.close }
    runners.each_value(&:close)
    h.as(h.users.first) { h.view(h.users.first)&.close }
    $lastactivecontrols = $activecontrols = []
  end
end

[:runner_first, :screen_first].each do |order|
  f = SharedDrawScreenFixture.new
  begin
    before = Marshal.dump(f.h.core.entries)
    native_reads = f.h.core.views.sum { |view| view.calls[:read] }
    f.deliver
    f.recipients.each do |user|
      step(f.h, f.runners[user], user) if order == :runner_first
      f.reads.clear
      f.as(user) do
        screen = f.screens[user]
        assert(screen.instance_variable_get(:@synchronizer).next_event&.kind == :game_changed,
          'Addressed delivery did not wake the existing UI feed')
        assert(screen.send(:prepared_runner_payload, f.waits[user].revision).nil?,
          'Fixture did not exercise the same-public-revision fallback')
      end
      assert(f.refresh(user), "#{order}/#{user}: delivered private card did not refresh GameScreen")
      assert(!f.reads.empty? && f.reads.all? { |_, thread| thread != Thread.current },
        'The private projection was read from the UI thread')
      f.as(user) do
        assert(!f.screens[user].send(:handle_signal_wait, f.waits[user], nil),
          'An unchanged private projection kept forcing refreshes')
      end
    end
    (f.h.users + ['Observer'] - f.recipients - [f.giver]).each do |user|
      f.as(user) do
        assert(!f.screens[user].send(:handle_signal_wait, f.waits[user], nil),
          "#{user}: a foreign private card refreshed the hidden view")
        snapshot = f.h.repositories[user].snapshot_for(f.h.session)
        replay = f.h.game.replay(snapshot.session, snapshot.events, f.h.repositories[user])
        assert(snapshot.session.fetch('__shared_draws', {}).empty? &&
          f.h.game.card_lines(replay.state, user).empty?, "#{user}: received a hidden phrase")
      end
    end
    assert(Marshal.dump(f.h.core.entries) == before, 'Private delivery appended a public move')
    assert(f.h.core.views.sum { |view| view.calls[:read] } == native_reads,
      'Addressed delivery introduced an unnecessary server stack read')
    # A subsequent real game boundary still wins over a retained shared card.
    f.h.start
    user = f.recipients.first
    f.reads.clear
    f.as(user) do
      assert(f.screens[user].send(:handle_signal_wait, f.waits[user], nil), 'Rematch was ignored')
      assert(f.waits[user].action == :new_session &&
        f.screens[user].instance_variable_get(:@new_session_id) == f.h.session['__id'],
        'A stale private projection masked the new session')
      assert(f.reads.empty?, 'Old private draw was projected before the rematch boundary')
    end
    puts "PASS #{order}: same-revision addressed card refresh, native list/chat, worker-only reads and hidden viewers"
  ensure
    f&.close
  end
end
