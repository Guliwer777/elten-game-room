require_relative '../support/background_help_game_screen'
require_relative '../support/session_runner'

def intent_fixture(game = GameRoomGames::FourInARow.new, users: %w[Alice Bob], viewer: 'Alice')
  options = game.default_options.merge('round_time' => 0)
  if game.id == 'categories'
    options = game.normalize_options(options.merge('category_set' => 'custom',
      'custom_categories' => %w[country city], 'round_category_count' => 2))
  end
  h = NativeRoomHarness.new(game: game, users: users, options: options)
  h.start
  if game.id == 'categories'
    startup = runner_for(h, 'Alice')
    step(h, startup, count: 2)
    startup.close
  end
  program = ProgramDouble.new(h.broker.endpoint(viewer))
  transport = h.transports.fetch(viewer)
  repository = h.repositories.fetch(viewer)
  sync = GameRoomSync::Controller.new(transport: transport, table_id: h.table['__id'], session_id: h.session['__id'])
  screen = GameScreen.new(program: program, repository: repository, game: game, session: h.session,
    table: h.table, table_owner: 'Alice', synchronizer: sync, game_services: {transport: transport},
    room_snapshot_provider: -> {
      data = transport.room_snapshot(h.table)
      data && LobbyRepository::TableSnapshot.new(**data)
    })
  runner = runner_for(h, viewer, covered: -> { false })
  screen.instance_variable_set(:@session_runner, runner)
  screen.define_singleton_method(:alert) { |text| raise "Unexpected alert: #{text}" }
  $game_room_test_user = viewer
  [h, screen, runner]
end

def capture_intent(h, screen, actor, selection)
  current = h.replay(actor)
  session = h.repositories.fetch(actor).snapshot_for(h.session).session
  screen.instance_variable_set(:@session, session)
  wait = GameScreen::WaitState.new(session: session, replay: current, revision: nil,
    membership: h.transports.fetch(actor).membership_token(h.table['__id']), actor: actor)
  assert(h.as(actor) { screen.send(:capture_pending_move, wait, selection) }, 'Could not capture the displayed move intent')
  screen.instance_variable_get(:@pending_move_intent)
end

def drain_intent(h, screen, actor)
  h.as(actor) { screen.send(:submit_pending_move) }
end

# Exact payload ownership: editing the originating selection after Enter must
# not change the later action. Table/account/visit/epoch changes must drop it.
%i[changed_turn new_game control_epoch rejoin account aborted].each do |boundary|
  h, screen, runner = intent_fixture
  begin
    selection = h.game.legal_actions(h.replay('Alice'), 'Alice').first
    intent = capture_intent(h, screen, 'Alice', selection)
    selection['x'] = 6
    assert(intent.selection['x'] == 0, "#{boundary}: intent retained mutable selection")
    case boundary
    when :changed_turn
      h.submit('Alice', h.game.legal_actions(h.replay('Alice'), 'Alice').first)
      h.submit('Bob', h.game.legal_actions(h.replay('Bob'), 'Bob').first)
      assert(h.replay('Alice').current_player == 'Alice', 'Round-trip turn fixture failed')
    when :new_game
      h.start
    when :control_epoch
      view = h.view('Alice')
      view.transfer_ownership(view.participants.find { |participant| participant.user == 'Bob' })
    when :rejoin
      h.as('Alice') do
        lobby = LobbyRepository.new(ProgramDouble.new(h.broker.endpoint('Alice')),
          transport: h.transports.fetch('Alice'), server_tables: Object.new)
        assert(lobby.leave_table(h.table, 'Alice') == :left, 'Native owner leave fixture failed')
      end
      returned = h.as('Alice') do
        transport = h.transports.fetch('Alice')
        discovered = transport.discover_rooms.find { |table| table['__id'] == h.table['__id'] }
        transport.establish_membership(table_id: h.table['__id'], owner: 'Bob', capacity: 8,
          user: 'Alice', table: discovered)
      end
      assert(returned, 'Native rejoin fixture failed')
    when :aborted
      h.as('Alice') { h.transports['Alice'].abort_game(h.session) }
    end
    before = h.core.entries.length
    accepted = drain_intent(h, screen, boundary == :account ? 'Bob' : 'Alice')
    assert(!accepted, "#{boundary}: stale gesture became a new valid move")
    assert(h.core.entries.length == before, "#{boundary}: stale gesture wrote a native packet")
    assert(screen.instance_variable_get(:@pending_move_intent).nil?, "#{boundary}: stale gesture stayed queued")
  ensure
    runner.close
  end
end

# Another participant's answer is not a reason to discard this completed
# sheet. Copy the nested answers before the editor can be changed again.
h, screen, runner = intent_fixture(GameRoomGames::Categories.new, users: %w[Alice Bob Carol], viewer: 'Bob')
begin
  selection = {'kind' => 'answer_sheet', 'action' => 'submit', 'answers' => {'country' => 'Argentina'}}
  capture_intent(h, screen, 'Bob', selection)
  selection['answers']['country'] = 'Mutated after Enter'
  carol = runner_for(h, 'Carol', covered: -> { false })
  h.as('Carol') do
    assert(carol.submit(session: h.session, replay: h.replay('Carol'), actor: 'Carol',
      selection: {'kind' => 'answer_sheet', 'action' => 'submit', 'answers' => {'country' => 'Austria'}}).first == :ok,
      'Other participant answer setup failed')
  end
  assert(drain_intent(h, screen, 'Bob'), 'Independent participant answer wrongly invalidated the captured sheet')
  replay = h.replay('Bob')
  envelope = runner.send(:context).hidden_submissions.reveal(session_id: h.session['__id'],
    round_id: h.game.send(:round_id, replay.state), user: 'Bob')
  assert(envelope.payload.fetch('country') == 'Argentina', 'Pending sheet read mutable editor data instead of the submitted snapshot')
  assert(replay.state[:commitments].keys.sort == %w[Bob Carol] && replay.state[:reveals].empty?,
    'Concurrent pending answer lost a commitment or prematurely exposed the answers')
  assert(h.events('Bob').none? { |event| event['value'].include?('Argentina') }, 'Captured private answer leaked into public events')
ensure
  runner.close
  carol&.close
end

# The same command kind is not sufficient: after a cancelled attempt a new
# letter/question must never inherit the previously entered answers.
h, screen, runner = intent_fixture(GameRoomGames::Categories.new, users: %w[Alice Bob Carol], viewer: 'Bob')
begin
  capture_intent(h, screen, 'Bob', {'kind' => 'answer_sheet', 'action' => 'submit', 'answers' => {'country' => 'Argentina'}})
  old_attempt = h.replay('Bob').state[:attempt]
  %w[close_answers start_review cancel_round].each do |action|
    h.submit('Alice', {'kind' => 'command', 'action' => action})
  end
  context = GameRoomGames::ActionContext.new(session_id: h.session['__id'], table_id: h.table['__id'],
    now: Time.now.to_i + 5, random_source: GameRoomRandom::LocalSecureSource.new)
  h.submit('Alice', context: context)
  assert(h.replay('Bob').state[:attempt] == old_attempt + 1, 'Replacement question fixture failed')
  before = h.core.entries.length
  assert(!drain_intent(h, screen, 'Bob'), 'Old private sheet was accepted into a new attempt')
  assert(h.core.entries.length == before && h.replay('Bob').state[:commitments].empty?,
    'New attempt received a stale private commitment')
ensure
  runner.close
end

# A review sheet is not an independent answer: a changed grade revision must
# invalidate a queued aggregate decision even when the same review stays open.
h, screen, runner = intent_fixture(GameRoomGames::Categories.new, users: %w[Alice Bob Carol])
answerers = {}
begin
  %w[Bob Carol].each do |actor|
    answerers[actor] = runner_for(h, actor, covered: -> { false })
    h.as(actor) do
      result = answerers[actor].submit(session: h.session, replay: h.replay(actor), actor: actor,
        selection: {'kind' => 'answer_sheet', 'action' => 'submit', 'answers' => {'country' => "#{actor}-country"}})
      assert(result.first == :ok, 'Review fixture answer failed')
    end
  end
  h.submit('Alice')
  answerers.each do |actor, answerer|
    replay = h.replay(actor)
    selection = h.game.automatic_action(replay, actor, context: answerer.send(:context))
    h.as(actor) do
      assert(answerer.submit(session: h.session, replay: replay, actor: actor, selection: selection).first == :ok,
        'Review fixture reveal failed')
    end
  end
  h.submit('Alice')
  review = h.replay('Alice')
  assert(review.state[:phase] == :review, 'Review fixture did not open review')
  decisions = h.game.send(:review_items, review.state).to_h { |item| [item[:id], 'unique'] }
  assert(decisions.length == 2, 'Review fixture must contain both submitted country answers')
  selection = {'kind' => 'review', 'action' => 'finish', 'decisions' => decisions}
  intent = capture_intent(h, screen, 'Alice', selection)
  first_id = decisions.keys.first
  decisions[first_id] = 'incorrect'
  assert(intent.selection['decisions'][first_id] == 'unique', 'Captured review retained mutable decisions')
  h.submit('Alice', {'kind' => 'review', 'action' => 'change', 'item_id' => first_id, 'decision' => 'partial'})
  before = h.core.entries.length
  assert(!drain_intent(h, screen, 'Alice'), 'Stale aggregate review overwrote a newer grade')
  assert(h.core.entries.length == before && h.replay('Alice').state[:decisions] == {first_id => 'partial'} &&
    !h.replay('Alice').state[:review_finished], 'Stale aggregate review wrote or finalized unrelated decisions')
ensure
  runner.close
  answerers.each_value(&:close)
end

puts 'PASS independent move-intent boundaries: immutable payload, complete turn cycle, new game, control epoch, new membership, account, abort, concurrent private sheet, new private attempt and changed review'
