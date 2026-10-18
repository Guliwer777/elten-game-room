class GameRoomLiveSessionStore
  # Owned by the store mutex. A room is evicted as one generation, so no
  # parallel cache can survive its records or be reused by an old callback.
  class RoomState
    attr_accessor :records, :record_keys, :message_records, :pending_move,
      :recovered_moves, :stack_cursor, :received_sequences, :private_game_messages,
      :record_generation, :validated_records, :control_lock, :attachment, :ownership_token,
      :io_count, :subscription_count, :public_game_previews, :private_draws, :verified_pools, :shared_draws, :shared_draw_lock
    attr_reader :clock_revisions

    def initialize
      @records, @recovered_moves, @private_game_messages = [], [], []
      @public_game_previews = []
      @private_draws, @verified_pools = {}, {}
      @shared_draws = {}
      @shared_draw_lock = Mutex.new
      @record_keys, @message_records, @received_sequences = {}, {}, {}
      @clock_revisions = Hash.new(0)
      @ownership_token = Object.new
      @stack_cursor = @record_generation = @io_count = @subscription_count = 0
    end

    def retained?
      @pending_move || @io_count.positive? || @subscription_count.positive? ||
        !@recovered_moves.empty? || !@private_game_messages.empty? || @control_lock&.locked?
    end

    def take_recovered_moves
      result, @recovered_moves = @recovered_moves, []
      result
    end

    def take_private_game_messages
      result, @private_game_messages = @private_game_messages, []
      result
    end

    def take_public_game_previews
      result, @public_game_previews = @public_game_previews, []
      result
    end
  end

  private

  def room_state(table_id)
    @rooms[table_id] ||= RoomState.new
  end
end
