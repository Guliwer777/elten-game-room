require "json"
require "fileutils"
require_relative "../../support/assertions"
require_relative "../../support/elten_array_shuffle"
require_relative "../../../games/duck_racing"
require_relative "../../../games/duck_racing_support/bots"
require_relative "../../../content/scrabble_words_en"
require_relative "../../../lib/bot_turn_gate"

# Model fixtures, not live accounts. Controlled cards/positions are arranged
# explicitly; subsequent choices use the real game action_for and Session.
module DuckBotFixture
  include GameRoomTest::Assertions
  LOGIC = GameRoomDuckRacing
  GAME = GameRoomGames::DuckRacing
  FINGERPRINT = "b" * 64

  def self.resources
    @resources ||= begin
      registry = GameRoomContent::Registry.new
      registry.register_language(GameRoomContent.registry.language("en"))
      registry.register_pack(GameRoomContent::Pack.new(id: "test.duck.bots.quiz", set_id: "test.duck.bots.quiz",
        title: "Bot fixture", version: 1, language_id: "en", game_ids: ["quiz"], kind: "quiz", data: {"questions" => [
          {"id" => "bot-1", "category" => "Test", "prompt" => "How many wheels?", "correct" => "four", "wrong" => %w[one two three]}
        ]}))
      {questions: LOGIC::QuestionSets.prepare_selected(ids: ["test.duck.bots.quiz"], language: "en", registry: registry),
        fingerprint: FINGERPRINT}.freeze
    end
  end

  def semantic(value)
    case value
    when Hash then value.transform_values { |item| semantic(item) }
    when Array then value.map { |item| semantic(item) }
    when Random then Marshal.dump(value)
    when Data then [value.class.name, semantic(value.to_h)]
    else value
    end
  end

  def self.game(cache: nil)
    game = GAME.new(resources: resources)
    game.instance_variable_set(:@bot_cache, cache || LOGIC::BotCache.new)
    game
  end

  class Fixture
    include GameRoomTest::Assertions
    include DuckBotFixture
    attr_reader :state, :game, :players, :vault, :events

    def initialize(kind: "copy_number", count: 2, seed: 1, game: nil, laps: 3)
      @game = game || DuckBotFixture.game
      @players = Array.new(count) { |seat| GameRoomParticipants.bot_id(777, seat + 1) }
      @vault = HiddenSubmissions::Vault.new(HiddenSubmissions::MemoryStorage.new)
      @events = []
      @state = LOGIC::Session.initial(session_id: 777, player_count: count, laps: laps,
        enabled_challenges: [kind], fingerprint: FINGERPRINT)
      initial = {"action" => "start", "seed" => seed, "revision" => 0}
      assert(LOGIC::Session.apply(@state, initial, seat: 0, moderator: true, now_ms: 1_000, resources: DuckBotFixture.resources))
      @state.merge!(players: @players, options: @game.default_options.merge("bot_delay" => 0, "laps" => laps,
        "word_language" => "en", "question_language" => "en", "challenges" => [kind]),
        owner: @players.first, bot_controller_epoch: "initial", duck_challenge_events: [])
    end

    def replay
      race = @state[:race]
      winner = race[:winner] && @players[race[:winner]]
      GameRoomGames::Replay.new(board: nil, players: @players,
        current_player: @state[:round] || winner ? nil : @players[race[:turn]],
        winner: winner, draw: false, accepted_events: @events, history: [], state: @state)
    end

    def context(now)
      GameRoomGames::ActionContext.new(session_id: 777, table_id: 777, options: @state[:options],
        hidden_submissions: @vault, now: now / 1000.0, table_owner: @players.first,
        local_data: {"duck_host" => true}, random_source: GameRoomRandom::LocalSecureSource.new)
    end

    def apply(selection, seat: 0, at:)
      before = Marshal.dump(@state)
      status, plan = @game.action_for(selection, replay, @players[seat], context: context(at))
      assert_equal(before, Marshal.dump(@state), "Planning an action mutated accepted state")
      assert_equal(:ok, status, "Game rejected #{selection.inspect}")
      rows = plan.events.each_with_index.map do |event, index|
        {"__id" => @events.length + index + 1, "actor" => @players[seat], "action" => event.action, "value" => event.value}
      end
      repository = Object.new
      def repository.actor_of(event, _); event["actor"]; end
      applied = false
      LOGIC::Session.copy(@state).tap do |candidate|
        GameRoomActionPayload.each(rows, "duck_racing", repository, {}) do |data, _, _|
          round_before = candidate[:round]
          assert(LOGIC::Session.apply(candidate, data, seat: seat, moderator: true, now_ms: at, resources: DuckBotFixture.resources))
          current = candidate[:round]
          if current && current[:engine] && round_before && %w[input advance].include?(data["action"])
            candidate[:duck_challenge_events] << {action: data["action"], seat: seat,
              at: at - current[:started_at], input: LOGIC::Session.copy(data["input"])}
          elsif !current || current[:challenge][:id] != round_before&.dig(:challenge, :id)
            candidate[:duck_challenge_events] = []
          end
          applied = true
        end
        @state = candidate if applied
      end
      assert(applied)
      @events.concat(rows)
      plan
    end

    def card(type, seat: 0)
      card = LOGIC::Cards::Copy.new("bot-fixture-#{seat}-#{type}", type)
      @state[:race][:racers][seat][:hand] << card
      card
    end

    def challenge
      card = card("super_challenge")
      apply({"kind" => "duck", "action" => "race", "input" => {"kind" => "play", "card" => card.id}}, at: 1_100)
      @players.each_index do |seat|
        apply({"kind" => "duck", "action" => "ready", "challenge" => @state[:round][:challenge][:id],
          "fingerprint" => FINGERPRINT}, seat: seat, at: 1_199)
      end
      apply({"kind" => "duck", "action" => "begin", "challenge" => @state[:round][:challenge][:id]}, at: 1_200)
    end

    def choose(seat:, at:, game: @game)
      actor = @players[seat]
      GameRoomBots::Coordinator.new.decide(game: game, replay: replay, actor: actor, context: context(at))&.action
    end

    def alive(at:)
      return unless @state[:round]
      @state[:round][:challenge][:participants].each do |seat|
        last = @state[:round][:last_seen][seat]
        next if at - last < LOGIC::Session::PULSE_MS
        apply({"kind" => "duck", "action" => "alive", "challenge" => @state[:round][:challenge][:id]}, seat: seat, at: at)
      end
    end
  end
end
