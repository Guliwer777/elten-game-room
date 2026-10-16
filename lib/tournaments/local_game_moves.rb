require_relative 'local_fixed_team_moves'
require_relative 'game_selection'
require_relative 'realtime_point_input'
module GameRoomTournaments
  # Randomness is recorded as an input to the game's existing action_for.
  # Readback verifies the original selection without rerolling dice/cards.
  class MoveRandomness
    attr_reader :rolls
    def initialize(rolls: nil)
      @replaying = !rolls.nil?
      @pending = rolls && Publication::Data.copy(rolls)
      @rolls = []
      @source = GameRoomRandom::LocalSecureSource.new unless @replaying
    end
    def roll(count:, sides:)
      if @replaying
        value = @pending.shift
        unless value.is_a?(Hash) && value.keys.sort == %w[count sides source proof values].sort &&
            value['count'].eql?(count) && value['sides'].eql?(sides) && count.is_a?(Integer) && sides.is_a?(Integer) &&
            count.between?(1, 100) && sides.between?(2, 1000) && value['source'] == 'local_secure' && value['proof'].nil? &&
            value['values'].is_a?(Array) && value['values'].size == count &&
            value['values'].all? { |number| number.is_a?(Integer) && number.between?(1, sides) }
          raise ArgumentError, 'Invalid recorded randomness'
        end
        GameRoomRandom::Roll.new(values: value['values'], sides: sides, source: value['source'], proof: value['proof'])
      else
        result = @source.roll(count: count, sides: sides)
        @rolls << {'count' => count, 'sides' => sides, 'values' => result.values.dup, 'source' => result.source, 'proof' => result.proof}
        raise ArgumentError, 'Too much randomness' if @rolls.size > 64
        result
      end
    end
    def consumed?; !@replaying || @pending.empty?; end
    def authoritative?; false; end
    def source_name; 'local_secure'; end
  end

  class LocalGameMoves < LocalFixedTeamMoves
    def self.receipt_fields(receipt = nil)
      FIELDS + ['randomness'] + (receipt&.key?('action_time') ? ['action_time'] : []) + (receipt&.key?('selection_ref') ? ['selection_ref'] : []) + (receipt&.key?('realtime_input') ? ['realtime_input'] : [])
    end
    def self.listed_action_required?; false; end
    def self.valid_command_count?(count); count.between?(1, GameRepository::MAX_EVENTS_PER_ACTION); end
    def self.command_matches?(_selection, _command); true; end
    def self.validate_game_selection!(game, replay, user, receipt, session:, owner:, selection: receipt['selection'], hidden_submissions: nil, request: nil)
      rolls = receipt['randomness']
      raise ArgumentError, 'Invalid randomness' unless rolls.is_a?(Array) && rolls.size <= 64
      source = MoveRandomness.new(rolls: rolls)
      now = receipt['action_time']
      if receipt.key?('action_time') && !(now.is_a?(Integer) || (now.is_a?(Float) && now.finite?))
        raise ArgumentError, 'Invalid action time'
      end
      local_data = {}
      if receipt.key?('realtime_input')
        local_data = RealtimePointInput.validate!(receipt['realtime_input'], request: request, game: game, selection: selection,
          native_uuid: receipt['native_uuid'], table_id: receipt['table_id'], session_id: receipt['session_id'],
          control_epoch: receipt['record']['packet']['data']['control_epoch'])
      elsif game.tournament_execution_kind == :realtime && selection['action'] == game.tournament_realtime_point_action
        raise ArgumentError, 'Missing agreed realtime input'
      end
      context = GameRoomGames::ActionContext.new(random_source: source, local_data: local_data, now: now, hidden_submissions: hidden_submissions,
        session_id: receipt['session_id'], table_id: receipt['table_id'], table_owner: owner,
        options: game.options_from_json(session['options']))
      status, plan = game.action_for(GameSelection.decode(selection), replay, user, context: context)
      commands = receipt['record']['packet']['data']['events'].map { |event| event.slice('action', 'value') }
      unless status == :ok && plan.is_a?(GameRoomGames::ActionPlan) && source.consumed? &&
          (!hidden_submissions.respond_to?(:consumed?) || hidden_submissions.consumed?) &&
          plan.events.map { |event| {'action' => event.action, 'value' => event.value} } == commands
        raise ArgumentError, 'Selection differs from recorded commands'
      end
    end
    private
    def action_context
      GameRoomGames::ActionContext.new(random_source: MoveRandomness.new, local_data: {})
    end
    def context_receipt(context); {'randomness' => context.random_source.rolls, 'action_time' => context.now}; end
    def runner_options(context)
      {action_context_observer: ->(actual) { context.now = actual.now }}
    end
  end
end
