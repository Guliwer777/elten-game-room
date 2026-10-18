require 'json'
require_relative '../../lib/game_surfaces/specifications'
require_relative '../../lib/game_random'
require_relative '../../lib/hidden_submissions'
require_relative '../../games/base'

# This fixture tests the game-owned consumer of the trusted projection, not
# the server boundary that supplies the marker or the 300-second clock.
module TournamentEliminationModel
  def self.assert(value, message)
    raise message unless value
  end

  class Repository
    def initialize(players); @players = players; end
    def players_for(_session); @players; end
    def actor_of(event, _session = nil); event.fetch('actor'); end
    def event_id(event); event.fetch('id'); end
  end

  class Fixture
    attr_reader :game, :players, :options, :session, :events, :repository, :vault
    attr_accessor :now

    def initialize(game, players: %w[Alice Bob Carol Dave], options: {}, session_id: 71)
      @game, @players = game, players
      @options = game.normalize_options(game.default_options.merge(options))
      @session = {'__id'=>session_id, 'options'=>JSON.generate(@options)}
      @repository = Repository.new(players)
      @events = []
      @now = 100
      @vault = HiddenSubmissions::Vault.new(HiddenSubmissions::MemoryStorage.new)
      @random = GameRoomRandom::SeededSource.new(4242)
    end

    def replay; game.replay(session, events, repository); end

    def context
      GameRoomGames::ActionContext.new(session_id:session.fetch('__id'), table_id:4,
        hidden_submissions:vault, random_source:@random, now:now)
    end

    def event(actor, action, value = '', extra = {})
      {'id'=>events.length + 1, 'actor'=>actor, 'action'=>action,
        'value'=>value.to_s, 'created_at'=>now}.merge(extra)
    end

    def append(actor, action, value = '', extra = {})
      before = replay
      previous = before.accepted_events.length
      events << event(actor, action, value, extra)
      result = replay
      TournamentEliminationModel.assert(result.accepted_events.length == previous + 1,
        "#{game.id}: rejected fixture action #{actor}/#{action}/#{value}")
      incremental = game.incremental_replay(before, session, [events.last], repository)
      if incremental
        TournamentEliminationModel.assert(incremental.to_h == result.to_h, "#{game.id}: incremental elimination continuation differs")
      end
      result
    end

    def perform(actor, selection)
      status, plan = game.action_for(selection, replay, actor, context:context)
      TournamentEliminationModel.assert(status == :ok && plan, "#{game.id}: action_for returned #{status}")
      plan.events.each { |command| append(actor, command.action, command.value) }
      replay
    end

    def automatic(actor = players.first)
      action = game.automatic_action(replay, actor, context:context)
      TournamentEliminationModel.assert(action, "#{game.id}: no automatic action in #{replay.state[:phase]}")
      perform(actor, action)
    end

    def eliminate(*names)
      append(players.first, 'tournament_elimination', JSON.generate(names.map { |name| players.index(name) }),
        '__tournament_elimination'=>true)
    end

    def refuse(actor, action, value = '', extra = {})
      before = replay
      result = game.replay(session, events + [event(actor, action, value, extra)], repository)
      TournamentEliminationModel.assert(result.to_h == before.to_h, "#{game.id}: accepted invalid #{action}")
    end

    def assert_cold
      cold = game.class.new
      if game.respond_to?(:content_registry)
        registry = game.content_registry
        cold.define_singleton_method(:content_registry) { registry }
      end
      result = cold.replay(JSON.parse(JSON.generate(session)), JSON.parse(JSON.generate(events)), Repository.new(players.dup))
      TournamentEliminationModel.assert(result.to_h == replay.to_h, "#{game.id}: cold replay differs")
    end

    def assert_roster(active)
      result = replay
      TournamentEliminationModel.assert(result.players == players && result.state[:players] == players,
        "#{game.id}: original seats changed")
      TournamentEliminationModel.assert(game.tournament_active_players(result, options:options) == active,
        "#{game.id}: wrong active seats")
      (players - active).each do |player|
        TournamentEliminationModel.assert(game.eliminated_from_game?(result, player), "#{game.id}: no eliminated status")
        TournamentEliminationModel.assert(game.legal_actions(result, player).empty?, "#{game.id}: removed player can move")
      end
      assert_cold
    end
  end
end
