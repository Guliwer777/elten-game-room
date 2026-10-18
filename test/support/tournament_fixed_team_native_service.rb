# encoding: UTF-8
require_relative 'native_live_sessions'

# Jawnie testowa usługa lokalna. Odtwarza broker, nie wywołuje create przy odczycie.
class TournamentFixedTeamNativeService
  class Broker < NativeLiveSessionsBroker
    attr_reader :creates

    def initialize(state)
      super()
      @creates = state.fetch('creates', []).map(&:dup)
      state.fetch('cores', []).each do |raw|
        values = raw.transform_keys(&:to_sym)
        values[:visibility] = raw.fetch('visibility').to_sym
        values[:participants] = raw.fetch('participants').to_h do |key, person|
          [key, Participant.new(id: person.fetch('id'), user: person.fetch('user'))]
        end
        values[:dedup] = raw.fetch('dedup').to_h { |row| [row.fetch('key'), row.fetch('sequence')] }
        values[:mutex], values[:views] = Mutex.new, []
        cores[raw.fetch('id')] = Core.new(**values)
      end
    end

    def endpoint(user, fresh: false)
      @endpoints[user] ||= Endpoint.new(self, user)
    end

    def dump
      {'creates' => @creates, 'cores' => cores.values.map do |core|
        value = core.to_h.reject { |key, _| %i[mutex views].include?(key) }.transform_keys(&:to_s)
        value['visibility'] = core.visibility.to_s
        value['participants'] = core.participants.transform_values { |person| {'id' => person.id, 'user' => person.user} }
        value['dedup'] = core.dedup.map { |key, sequence| {'key' => key, 'sequence' => sequence} }
        value
      end}
    end

    class Endpoint < NativeLiveSessionsBroker::Endpoint
      # Match the production local transaction endpoint, not a live server.
      def offline?; true; end

      def initialize(broker, user)
        super
        broker.cores.each_value do |core|
          next unless core.owner == user && !core.closed
          view = NativeLiveSessionsBroker::View.new(self, core)
          @sessions << view
          core.views << view
        end
      end

      def create(**arguments)
        view = super
        @broker.creates << {'pid' => Process.pid, 'native_uuid' => view.id,
          'arguments' => arguments.transform_keys(&:to_s).merge('visibility' => arguments.fetch(:visibility).to_s)}
        view
      end
    end
  end

  def committed(receipt:)
    nil
  end

  def local_transaction_version
    1
  end

  def limits
    {'options_bytes' => 8192, 'discovery_bytes' => 1024, 'stack_entry_bytes' => 16_384, 'core_bytes' => 65_536}
  end

  def open(state:, owner:)
    Transaction.new(state, owner)
  end

  class Transaction
    attr_reader :program

    def initialize(state, owner)
      @broker = Broker.new(JSON.parse(JSON.generate(state)))
      @program = ProgramDouble.new(@broker.endpoint(owner))
    end

    def metadata(native_uuid:)
      core = @broker.cores.fetch(native_uuid)
      {'metadata' => core.metadata, 'discovery' => core.discovery_metadata, 'stack' => core.entries,
        'visibility' => core.visibility.to_s, 'participants' => core.participants.transform_values { |person| {'id' => person.id, 'user' => person.user} }}
    end

    def dump
      @broker.dump
    end
  end
end
