require_relative '../support/ui'
require_relative '../../lib/game_surfaces'
require_relative '../support/session_runner'
require_relative '../../lib/game_screen'

FormTimer = EltenAPI::Controls::FormTimer unless defined?(FormTimer)
include GameRoomTest::Assertions
$game_room_test_user = 'Alice'

class ForegroundSnapshotFixture
  attr_reader :native, :runner, :screen, :wait, :before, :repository

  def initialize
    @native = NativeRoomHarness.new(game: GameRoomGames::TicTacToe.new, users: %w[Alice Bob])
    native.start
    @repository = native.repositories.fetch('Alice')
    @runner = runner_for(native, 'Alice', covered: -> { false })
    native.as('Alice') { runner.step }
    @before = repository.snapshot_for(native.session)
    sync = GameRoomSync::Controller.new(transport: native.transports.fetch('Alice'),
      table_id: native.table['__id'], session_id: native.session['__id'])
    @screen = GameScreen.new(program: ProgramDouble.new(native.broker.endpoint('Alice')),
      repository: repository, game: native.game, session: before.session, table: native.table,
      table_owner: 'Alice', synchronizer: sync,
      room_snapshot_provider: -> { LobbyRepository::TableSnapshot.new(**native.transports['Alice'].room_snapshot(native.table)) })
    screen.instance_variable_set(:@session_runner, runner)
    screen.instance_variable_set(:@room_snapshot, runner.presentation_snapshot.room)
    @wait = GameScreen::WaitState.new(replay: native.game.replay(before.session, before.events, repository),
      revision: repository.events_revision(before.events), action: :check_signal)
  end

  def move
    native.submit('Alice', native.game.legal_actions(native.replay('Alice'), 'Alice').first)
    native.as('Alice') { runner.step }
  end

  def candidate; screen.send(:prepared_runner_payload, wait.revision); end
  def close; runner.close; native.as('Alice') { native.view('Alice')&.close }; end
end

checks = 0
check = lambda do |name, &block|
  fixture = ForegroundSnapshotFixture.new
  block.call(fixture)
  checks += 1
  puts "PASS #{name}"
ensure
  fixture&.close
end

check.call('new confirmed log uses the owned full snapshot without either Tasks read') do |f|
  f.move
  source = f.runner.presentation_snapshot
  assert(source.snapshot.session['__game_revision'] != f.before.session['__game_revision'], 'The native move did not change its write-CAS token')
  assert_equal(f.before.session.reject { |key, _| key == '__game_revision' },
    source.snapshot.session.reject { |key, _| key == '__game_revision' }, 'The ordinary move changed semantic session metadata')
  original = EltenAPI::Tasks.method(:run)
  begin
    EltenAPI::Tasks.define_singleton_method(:run) { |**_options| raise 'A redundant Tasks read was started' }
    assert(f.screen.send(:handle_signal_wait, f.wait, nil))
    assert_equal(:refresh, f.wait.action)
    payload = f.screen.send(:fetch_game_payload)
    assert_equal(source.snapshot.events, payload.first.events)
    assert_equal(source.room, payload[1])
    assert_equal(source.activity, payload[2])
    assert(!source.snapshot.equal?(payload.first))
    assert(!source.snapshot.events.equal?(payload.first.events))
    assert(!source.room.equal?(payload[1]))
    payload.first.events.first['value'].replace('not a move')
    payload[1].members << 'Not a member'
    assert_equal(1, f.native.replay('Alice').accepted_events.length)
    assert(!source.room.members.include?('Not a member'))
    assert_equal(nil, f.screen.instance_variable_get(:@pending_runner_payload))
  ensure
    EltenAPI::Tasks.define_singleton_method(:run, original)
  end
end

check.call('packet and raw snapshot must agree even on the write-CAS token') do |f|
  f.move
  assert(f.candidate)
  changed = GameRoomSnapshot.copy(f.runner.presentation_snapshot)
  changed.session = GameRoomSnapshot.copy(changed.session)
  changed.session['__game_revision'] = 'unconfirmed-packet-cas'
  f.runner.instance_variable_set(:@presentation_snapshot, changed)
  assert_equal(nil, f.candidate)
end

check.call('a changed CAS does not make an incomplete runner packet usable') do |f|
  f.move
  confirmed = f.runner.presentation_snapshot
  assert(f.candidate)
  %i[snapshot room replay].each do |field|
    changed = GameRoomSnapshot.copy(confirmed)
    changed[field] = nil
    f.runner.instance_variable_set(:@presentation_snapshot, changed)
    assert_equal(nil, f.candidate, "Missing #{field} bypassed snapshot admission")
  end
end

check.call('normal rendering preserves chat draft/focus and alone acknowledges the prepared view') do |f|
  view = f.screen.send(:prepare_action_view, f.wait.replay)
  layout = view.layout
  layout.form.index = layout.form.fields.index(layout.chat)
  layout.chat.set_text('A draft written while waiting')
  f.screen.send(:remember_layout_position)
  f.screen.send(:publish_session_view, f.wait.replay, layout.surface)
  old_view = f.runner.instance_variable_get(:@view)
  f.move
  assert(f.screen.send(:handle_signal_wait, f.wait, layout))
  payload = f.screen.send(:fetch_game_payload)
  assert_equal(old_view, f.runner.instance_variable_get(:@view), 'Reading a snapshot acknowledged an unrendered state')
  snapshot = payload.first
  replay = f.native.game.replay(snapshot.session, snapshot.events, f.repository)
  f.screen.instance_variable_set(:@session, snapshot.session)
  f.screen.instance_variable_set(:@room_snapshot, payload[1])
  rendered = f.screen.send(:prepare_action_view, replay)
  f.screen.send(:publish_session_view, replay, rendered.layout.surface)
  assert_equal('A draft written while waiting', rendered.layout.chat.text)
  assert_equal([:chat, 0], rendered.layout.focus_location)
  assert_equal(f.runner.send(:revision, f.runner.instance_variable_get(:@replay)), f.runner.instance_variable_get(:@view)[:revision])
  assert_raises(GameRoomSessionRunner::StaleView) do
    f.native.as('Alice') { f.runner.submit(session: f.before.session, replay: f.wait.replay,
      selection: {'x' => 1, 'y' => 1}, actor: 'Alice') }
  end
end

check.call('raw rejected input stays in the adopted log and the notification revision') do |f|
  f.move
  f.native.write('Bob', [GameRoomGames::EventCommand.new(action: 'invalid-fixture-action', value: 'rejected')])
  f.native.as('Alice') { f.runner.step }
  assert_equal(1, f.runner.presentation_snapshot.replay.accepted_events.length)
  assert_equal(2, f.runner.presentation_snapshot.snapshot.events.length)
  payload = f.candidate
  assert_equal(2, payload.first.events.length)
  assert_equal(f.repository.events_revision(f.native.events('Alice')), f.repository.events_revision(payload.first.events))
  replay = f.native.game.replay(payload.first.session, payload.first.events, f.repository)
  assert_equal(1, replay.accepted_events.length)
end

check.call('unchanged, older and corrected same-number log use the established read path') do |f|
  assert_equal(nil, f.candidate)
  f.move
  packet = f.runner.presentation_snapshot
  revision = f.repository.events_revision(packet.snapshot.events)
  assert_equal(nil, f.screen.send(:prepared_runner_payload, revision))
  assert_equal(nil, f.screen.send(:prepared_runner_payload, [revision[0] + 1, revision[1] + 1]))
  # A correction with the same count/ID must not be inferred from those numbers.
  # The ordinary repository/replay path remains responsible for full validation.
  changed = GameRoomSnapshot.copy(packet)
  changed.snapshot.events.first['value'] = 'corrected-fixture'
  f.runner.instance_variable_set(:@presentation_snapshot, changed)
  assert_equal(nil, f.screen.send(:prepared_runner_payload, revision))
end

%w[__control_epoch __table_owner __players __seat_changes options __clock_revision __server_started_at __clock_offset __frozen_at __id table_id __future_semantic_field].each do |field|
  check.call("changed session #{field} keeps the normal reconciliation path") do |f|
    f.move
    assert(f.candidate)
    changed = GameRoomSnapshot.copy(f.runner.presentation_snapshot)
    changed.session[field] = field == '__players' ? ['Alice', 'Carol'] : 'different'
    f.runner.instance_variable_set(:@presentation_snapshot, changed)
    assert_equal(nil, f.candidate)
  end
end

%w[__frozen __aborted __control_ready].each do |field|
  check.call("terminal/control boundary #{field} is never a fast acknowledgement") do |f|
    f.move
    changed = GameRoomSnapshot.copy(f.runner.presentation_snapshot)
    changed.session[field] = field == '__control_ready' ? false : true
    f.screen.instance_variable_set(:@session, GameRoomSnapshot.copy(changed.session))
    f.runner.instance_variable_set(:@presentation_snapshot, changed)
    assert_equal(nil, f.candidate)
  end
end

check.call('dirty, closed, failed and reconciling runner does not offer its previous read') do |f|
  f.move
  assert(f.runner.ready_presentation_snapshot)
  f.runner.instance_variable_set(:@dirty, true)
  assert_equal(nil, f.candidate)
  f.runner.instance_variable_set(:@dirty, false)
  f.runner.instance_variable_set(:@internal_error, RuntimeError.new('fixture error'))
  assert_equal(nil, f.candidate)
  f.runner.instance_variable_set(:@internal_error, nil)
  sync = f.runner.instance_variable_get(:@sync)
  sync.request_recovery!(delay: 30)
  assert_equal(nil, f.candidate)
  sync.synchronized!
  assert(f.candidate)
  f.runner.close
  assert_equal(nil, f.candidate)
end

check.call('UI recovery, pending move and game switch retain their existing boundary') do |f|
  f.move
  f.screen.instance_variable_set(:@automatic_recovery_pending, true)
  assert_equal(nil, f.candidate)
  f.screen.instance_variable_set(:@automatic_recovery_pending, false)
  sync = f.screen.instance_variable_get(:@synchronizer)
  sync.request_recovery!(delay: 30)
  assert_equal(nil, f.candidate)
  sync.synchronized!
  f.screen.instance_variable_set(:@pending_event_ids, [123])
  assert_equal(nil, f.candidate)
  f.screen.instance_variable_set(:@pending_event_ids, [])
  f.screen.instance_variable_set(:@new_session_id, 999)
  assert_equal(nil, f.candidate)
  f.screen.instance_variable_set(:@new_session_id, nil)
  assert(f.candidate)
end

check.call('native pending UI operation cannot be replaced by the fast read') do |f|
  f.move
  view = f.screen.send(:prepare_action_view, f.wait.replay)
  pending = GameRoomUI::PendingOperation.new(layout: view.layout, table_id: f.native.table['__id'],
    session_id: f.native.session['__id'], token: EltenAPI::Tasks::CancellationToken.new, title: 'Pending fixture write')
  begin
    assert(pending.active?)
    assert_equal(nil, f.candidate)
  ensure
    pending.close
  end
  assert(f.candidate)
end

check.call('a rematch between queueing and taking the ready payload discards it') do |f|
  f.move
  assert(f.screen.send(:handle_signal_wait, f.wait, nil))
  prior = f.runner.presentation_snapshot
  changed = GameRoomSnapshot.copy(prior)
  changed.session['__id'] += 1
  f.runner.instance_variable_set(:@presentation_snapshot, changed)
  tasks = []
  original = EltenAPI::Tasks.method(:run)
  begin
    EltenAPI::Tasks.define_singleton_method(:run) do |**options, &operation|
      tasks << options[:title]
      operation.call(nil, options[:cancellation_token] || EltenAPI::Tasks::CancellationToken.new)
    end
    f.native.as('Alice') { f.screen.send(:fetch_game_payload) }
    assert_equal(['Updating game'], tasks)
    assert_equal(nil, f.screen.instance_variable_get(:@pending_runner_payload))
  ensure
    EltenAPI::Tasks.define_singleton_method(:run, original)
  end
end

check.call('actual native rematch is discovered rather than reusing the old table payload') do |f|
  f.move
  old_id = f.native.session['__id']
  f.native.start
  f.native.as('Alice') { f.runner.step }
  assert(f.runner.presentation_snapshot.session['__id'] != old_id)
  assert_equal(nil, f.candidate)
  f.native.as('Alice') do
    assert_equal([:new_session, f.native.session['__id']], f.screen.send(:remote_game_update, f.wait.revision))
  end
end

check.call('a further native move between queueing and taking retains the exact CAS guard') do |f|
  f.move
  assert(f.screen.send(:handle_signal_wait, f.wait, nil))
  queued = f.screen.instance_variable_get(:@pending_runner_payload)
  f.native.submit('Bob', f.native.game.legal_actions(f.native.replay('Bob'), 'Bob').first)
  f.native.as('Alice') { f.runner.step }
  confirmed = f.runner.ready_presentation_snapshot
  assert_equal(2, confirmed.snapshot.events.length)
  assert(queued.first.session['__game_revision'] != confirmed.session['__game_revision'])
  tasks = []
  original = EltenAPI::Tasks.method(:run)
  begin
    EltenAPI::Tasks.define_singleton_method(:run) do |**options, &operation|
      tasks << options[:title]
      operation.call(nil, options[:cancellation_token] || EltenAPI::Tasks::CancellationToken.new)
    end
    payload = f.native.as('Alice') { f.screen.send(:fetch_game_payload) }
    assert_equal(['Updating game'], tasks)
    assert_equal(confirmed.snapshot.events, payload.first.events)
    assert_equal(confirmed.session, payload.first.session)
    assert_equal(nil, f.screen.instance_variable_get(:@pending_runner_payload))
  ensure
    EltenAPI::Tasks.define_singleton_method(:run, original)
  end
end

puts "PASS #{checks} foreground runner snapshot cases; actual native fixtures, no live network"
