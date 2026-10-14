# encoding: UTF-8
require_relative 'local_fixed_team_native_endpoint'

module GameRoomTournaments
  # Uczestnik istniejącego atomowego commit; nie ma własnych plików ani sieci.
  class LocalFixedTeamNativeProvider
    def initialize(capacity: 4)
      raise CoordinationContract::Blocked, :native_target_mismatch unless capacity.is_a?(Integer) && capacity.between?(1, 256)
      @capacity = capacity
    end
    class Clock
      def now
        value = Time.now.to_f
        raise CoordinationContract::Blocked, :invalid_clock unless value.finite? && value.positive?
        value
      end
      alias synchronize now
      def synchronized?; true; end
    end

    def local_transaction_version; 1; end
    def limits
      {'options_bytes' => 8192, 'discovery_bytes' => 1024, 'stack_entry_bytes' => 16_384, 'core_bytes' => 262_144}
    end
    def open(state:, owner:)
      Transaction.new(state: state, owner: owner, clock: Clock.new, expected_capacity: @capacity || 4)
    end
    def open_for_start(state:, owner:, native_uuid:)
      Transaction.new(state: state, owner: owner, clock: Clock.new, start_target: native_uuid, expected_capacity: @capacity || 4)
    end
    def open_for_move(state:, actor:, native_uuid:, session_id:, after:)
      Transaction.new(state: state, owner: actor, clock: Clock.new,
        move_target: {native_uuid: native_uuid, session_id: session_id, after: after}.freeze, expected_capacity: @capacity || 4)
    end
    def committed(receipt:)
      # Wszystko utrwalono już wspólnym commit. Nie tworzymy niczego ponownie.
      nil
    end

    class Transaction
      Program = Struct.new(:live_sessions)
      attr_reader :program
      def initialize(state:, owner:, clock:, start_target: nil, move_target: nil, expected_capacity: 4)
        @clock = clock
        @endpoint = LocalFixedTeamNativeEndpoint.new(state: state, owner: owner, clock: clock, start_target: start_target, move_target: move_target, expected_capacity: expected_capacity)
        complete = false
        primary = nil
        begin
          @program = Program.new(@endpoint).freeze
          complete = true
        rescue Exception => error
          primary = error
          raise error, cause: error.cause
        ensure
          unless complete
            begin
              @endpoint.close_view
            ensure
              raise primary, cause: primary.cause if primary
            end
          end
        end
      end
      def transport_options
        {clock: @clock, local_view: true}.freeze
      end
      def metadata(native_uuid:)
        @endpoint.metadata(native_uuid: native_uuid)
      end
      def dump
        @endpoint.dump
      end
      def close
        @endpoint.close_view
      end
    end
  end
end
