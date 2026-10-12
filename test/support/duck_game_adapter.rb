require 'json'
require_relative 'assertions'
require_relative 'elten_array_shuffle'
require_relative 'duck_challenge_ui'
require_relative '../../games/duck_racing'
require_relative '../../lib/game_repository'
require_relative '../../lib/game_random'
require_relative '../../lib/saved_games'
require_relative 'native_room_harness'

# Local adapter fixture. Real action_for, payload codec, repository author
# authentication, participant wrapper and archive validation are exercised.
# This helper performs no scenario when required and does not fake game rules.
module DuckGameAdapterTest
  include GameRoomTest::Assertions
  include DuckChallengeTest
  LOGIC = GameRoomDuckRacing

  def self.semantic(value)
    case value
    when Hash then value.to_h { |key, item| [key, semantic(item)] }
    when Array then value.map { |item| semantic(item) }
    when Random then Marshal.dump(value)
    when Data, Struct then [value.class.name, semantic(value.to_h)]
    else value
    end
  end

  class SeedSource
    def initialize(seed); @seed = seed; end
    def roll(count:, sides:)
      raise 'Unexpected randomness request' unless count == 16 && sides == 256
      values = Array.new(16) { |index| ((@seed >> ((15 - index) * 8)) & 255) + 1 }
      GameRoomRandom::Roll.new(values: values, sides: sides, source: 'adapter-fixture')
    end
  end

  class Storage
    def initialize; @data = {}; end
    def read_json(_path, default:); JSON.parse(JSON.generate(@data)); end
    def update_json(_path, default:); yield @data; end
  end

  class NativeHarness < NativeRoomHarness
    def submit_at(selection, actor:, author: actor, at:, seed: 17, vault: nil)
      repository = repositories.fetch(author)
      snapshot = repository.snapshot_for(session)
      @session = snapshot.session
      current = game.replay(snapshot.session, snapshot.events, repository)
      owner = snapshot.session.fetch('__table_owner')
      context = GameRoomGames::ActionContext.new(session_id: session.fetch('__id'), table_id: table.fetch('__id'),
        now: at / 1000.0, table_owner: owner, random_source: SeedSource.new(seed), hidden_submissions: vault,
        local_data: {'duck_host' => GameRoomParticipants.same?(author, owner),
          'duck_ready' => true, 'duck_seat' => current.players.index(actor),
          'duck_stack_entry_bytes' => transports.fetch(author).game_action_limits(table)['max_stack_entry_bytes']})
      status, plan = game.action_for(selection, current, actor, context: context)
      assert_equal(:ok, status, "Native action rejected: #{selection.inspect}")
      as(author) do
        repository.append_events(session: session, sequence: repository.next_sequence(session, snapshot.events),
          events: plan.events, actor: actor, controller: !GameRoomParticipants.same?(author, actor))
      end
      expected = current.accepted_events.length + plan.events.length
      assert_equal(expected, replay(author).accepted_events.length, 'Native replay dropped the new action')
      plan
    end

    def assert_converged(stage, expected_count: nil)
      stacks = users.map { |user| events(user) }
      assert(stacks.all? { |stack| stack == stacks.first }, "#{stage}: ordered stack differs")
      ids = stacks.first.map { |event| event['__id'] }
      assert(ids == ids.sort && ids == ids.uniq, "#{stage}: unordered or duplicated events")
      assert_equal(expected_count, ids.length) if expected_count
      snapshots = users.map { |user| DuckGameAdapterTest.semantic(GameRoomTest::ReplaySnapshot.capture(replay(user))) }
      # Random#hash/eql? use object identity. Array#uniq therefore rejects
      # otherwise identical states; compare the complete canonical RNG state.
      differences = GameRoomTest::ReplaySnapshot::FIELDS.reject do |field|
        snapshots.all? { |snapshot| snapshot[field] == snapshots.first[field] }
      end
      assert(differences.empty?, "#{stage}: replay differs: #{differences.join(', ')}")
    end
  end

  class Harness
    include DuckGameAdapterTest
    attr_reader :game, :repository, :session, :events, :resources, :vaults, :now_ms

    def initialize(count: 2, kind: 'guess_number', owner: 'Alice', options: {}, session_id: 91)
      @resources = challenge_resources.merge(fingerprint: 'a' * 64).freeze
      @game = GameRoomGames::DuckRacing.new(resources: @resources)
      @repository = GameRepository.allocate
      @session = {'__id' => session_id, '__players' => %w[Alice Bob Carol Dave Eve Frank Grace Heidi].first(count),
        '__table_owner' => owner, '__insertion_user' => owner, 'player_one' => 'Alice', 'table_id' => 41,
        'options' => JSON.generate(@game.normalize_options({'challenges' => [kind]}.merge(options)))}
      @events, @vaults, @next_id, @now_ms = [], {}, 0, 1_000_000
    end

    def players; @session.fetch('__players'); end
    def owner; @session.fetch('__table_owner'); end
    def owner=(value); @session['__table_owner'] = value; end
    def replay; @game.replay(@session, @events, @repository); end
    def host_actor; @game.automatic_actor(replay, owner, table_owner: owner); end
    def vault(user); @vaults[user] ||= HiddenSubmissions::Vault.new(HiddenSubmissions::MemoryStorage.new); end

    def context(actor, author: actor, seed: 17, at: @now_ms, local: {})
      GameRoomGames::ActionContext.new(session_id: @session.fetch('__id'), table_id: 41,
        now: at / 1000.0, table_owner: owner, random_source: SeedSource.new(seed), hidden_submissions: vault(actor),
        local_data: {'duck_host' => GameRoomParticipants.same?(author, owner), 'duck_seat' => players.index(actor),
          'duck_ready' => true, 'duck_stack_entry_bytes' => 16_384}.merge(local))
    end

    def plan(selection, actor: host_actor, author: actor, seed: 17, at: nil, snapshot: nil, local: {})
      @now_ms = at || @now_ms + 10
      @game.action_for(selection, snapshot || replay, actor,
        context: context(actor, author: author, seed: seed, at: @now_ms, local: local))
    end

    def append(plan, actor:, author: actor, authority: owner, controller: author != actor)
      GameRoomEventProtocol.validate_commands!(plan.events)
      plan.events.map do |command|
        @next_id += 1
        event = {'__id' => @next_id, 'id' => @next_id, 'sequence' => @next_id,
          'actor' => actor, '__insertion_user' => author, '__authority_user' => authority,
          '__controller' => controller, 'action' => command.action, 'value' => command.value,
          'created_at' => @now_ms / 1000}
        @events << event
        event
      end
    end

    def accept(selection, actor: host_actor, author: actor, **options)
      before = Marshal.dump([@session, @events])
      status, command = plan(selection, actor: actor, author: author, **options)
      assert_equal(before, Marshal.dump([@session, @events]), 'Planning changed durable inputs')
      assert_equal(:ok, status, "Rejected #{selection.inspect} by #{actor}/#{author}")
      written = append(command, actor: actor, author: author)
      accepted_ids = replay.accepted_events.map { |event| @repository.event_id(event) }
      assert(written.all? { |event| accepted_ids.include?(event['id']) }, 'Replay rejected an action_for plan')
      command
    end

    def decode(events = @events)
      result = []
      GameRoomActionPayload.each(events, @game.id, @repository, @session) { |*parts| result << parts }
      result
    end

    def start(seed: 17)
      accept({'action' => 'start'}, author: owner, seed: seed)
      replay
    end

    def seed_for(card, count: players.length)
      settings = @game.options_from_json(@session['options'])
      (1..10_000).find do |seed|
        state = LOGIC::Race.start(player_count: count, laps: settings['laps'],
          enabled_challenges: settings['challenges'], seed: seed)
        state[:racers][0][:hand].any? { |copy| copy.type == card }
      end || raise('No natural fixture deal found')
    end

    def open_round(group: true)
      type = group ? 'super_challenge' : 'challenge'
      start(seed: seed_for(type)) unless replay.state[:race]
      card = replay.state[:race][:racers][0][:hand].find { |copy| copy.type == type }
      assert(card, 'The natural deal has no challenge card')
      input = {'kind' => 'play', 'card' => card.id}
      input['target'] = 1 unless group
      accept({'action' => 'race', 'input' => input}, actor: players.first)
      assert(replay.state[:round], 'Challenge did not open')
      replay.state[:round][:challenge]
    end

    def begin_round
      before = replay
      id = before.state[:round][:challenge][:id]
      # Each player plans from the same revision, before any ready record.
      plans = before.state[:round][:challenge][:participants].reverse.map do |seat|
        actor = players.fetch(seat)
        status, ready = plan({'action' => 'ready', 'challenge' => id, 'fingerprint' => @resources[:fingerprint]},
          actor: actor, snapshot: before)
        assert_equal(:ok, status)
        [actor, ready]
      end
      plans.each { |actor, ready| append(ready, actor: actor) }
      assert_equal(plans.length, replay.state[:round][:ready].length, 'Concurrent ready actions were lost')
      accept({'action' => 'begin', 'challenge' => id}, author: owner)
      assert_equal(:playing, replay.state[:round][:phase])
      id
    end

    def private_traces
      challenge = replay.state[:round][:challenge]
      challenge[:participants].to_h do |seat|
        trace = LOGIC::ChallengeTrace.new(challenge, seat: seat, resources: @resources)
        state = trace.state
        action = case challenge[:kind]
        when 'guess_number'
          answer = state[:model][:answer]
          {kind: :answer, value: seat.zero? ? answer : (answer == 1 ? 2 : answer - 1), press_id: 1}
        when 'copy_number' then {kind: :answer, value: state[:model][:question][:number].to_s, press_id: 1}
        when 'rock_paper_scissors' then {kind: :choose, value: seat.zero? ? 'rock' : 'scissors', press_id: 1}
        else raise "Unsupported fixture private kind: #{challenge[:kind]}"
        end
        assert(trace.submit(action, at: 100 + seat * 100), 'Could not construct a valid local attempt')
        trace.tick(at: 120_000) if challenge[:kind] == 'guess_number' && !trace.finished?
        [seat, trace.snapshot]
      end
    end

    def finish_private
      round = replay.state[:round]
      id, private_state = round[:challenge][:id], round[:private]
      private_traces.each do |seat, trace|
        actor = players.fetch(seat)
        status, plan = self.plan({'action' => 'submit_trace', 'challenge' => id, 'trace' => trace}, actor: actor)
        assert_equal(:ok, status)
        recovered = LOGIC::PrivateRound.recover(private_state, seat: seat, user: actor, vault: vault(actor))
        assert(recovered, 'The local attempt was not durable before its commitment')
        append(plan, actor: actor)
        data = decode(@events.last(plan.events.length)).first.fetch(0)
        assert_equal('commit', data['action'])
        assert(!data.key?('trace') && !data.key?('page') && !data.key?('score'), 'Commit exposed a private attempt')
      end
      assert_equal(nil, replay.state[:last_resolution])
      accept({'action' => 'advance', 'challenge' => id}, author: owner)
      round[:challenge][:participants].each do |seat|
        actor = players.fetch(seat)
        protocol = replay.state[:round][:private]
        prepared = LOGIC::PrivateRound.recover(protocol, seat: seat, user: actor, vault: vault(actor))
        prepared.reveal_pages.each do |page|
          accept({'action' => 'reveal', 'challenge' => id, 'page' => page}, actor: actor)
        end
      end
      assert_equal(id, replay.state[:last_resolution][:id])
      assert(replay.state[:last_resolution][:settlement], 'Verified traces did not settle the challenge')
      id
    end

    def reach_save_boundary
      30.times do
        current = replay
        return current if @game.save_game_error(current).nil?
        round = current.state[:round]
        if round
          participant = players.fetch(round[:challenge][:participants].first)
          accept({'action' => 'cancel', 'challenge' => round[:challenge][:id], 'reason' => 'technical'}, actor: participant)
        else
          racer = current.state[:race][:racers].fetch(current.state[:race][:turn])
          skip = racer[:frozen_turns].positive? || racer[:skip_turns].positive?
          accept({'action' => 'race', 'input' => {'kind' => skip ? 'skip' : 'roll'}},
            actor: skip ? host_actor : current.current_player, author: skip ? owner : current.current_player)
        end
      end
      raise 'Did not reach a safe archive boundary'
    end

    def replace(seat, replacement)
      @session['__initial_players'] ||= players.dup
      following = players.dup
      following[seat] = replacement
      @next_id += 1
      (@session['__seat_changes'] ||= []) << {'id' => @next_id, 'players' => following}
      @session['__players'] = following
      @next_id
    end

    def archive
      saves = SavedGames.new(Storage.new, owner: owner)
      row = saves.put(game: @game, table: {'owner' => owner, 'name' => 'Duck adapter test'},
        snapshot: Struct.new(:session, :events).new(@session, @events), repository: @repository, now: 2_000)
      [saves, row]
    end

    def restore_native(saves, row)
      native = NativeHarness.new(game: @game, users: ([owner] + GameRoomParticipants.humans(row.fetch('players'))).uniq,
        options: @game.options_from_json(@session['options']))
      restored = saves.restored_data(row, game: @game, table_id: native.table.fetch('__id'), now: 3_000)
      session = native.as(owner) do
        native.repositories.fetch(owner).restore_session(table: native.table, game: @game.id,
          players: restored.fetch(:players), options: row.fetch('options'), restore: restored)
      end
      native.instance_variable_set(:@session, session)
      [native, restored]
    end
  end
end
