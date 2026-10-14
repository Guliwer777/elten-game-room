require_relative '../hidden_submissions'
require_relative 'local_execution_plan_storage'
require_relative 'local_readiness_session'
module GameRoomTournaments
  # Local test secrets are separate from public execution receipts. The facade
  # can read/write only its captured actor and native game session.
  class LocalPrivateChoices
    Data = Publication::Data
    attr_reader :session_id
    def self.copy(value)
      Data.copy(value, max_bytes: 8_388_608, max_nodes: 131_072, max_depth: 20)
    end
    def self.input_round(id); 'move:' + Digest::SHA256.hexdigest(id); end
    def self.identity(backend_identity:, scope_digest:, actor:, session_id:)
      Digest::SHA256.hexdigest(JSON.generate([backend_identity, scope_digest, actor, session_id]))
    end
    class ReadOnlyVault
      class Snapshot
        def initialize(root); @root = root; end
        def read; LocalPrivateChoices.copy(@root); end
        def update; raise HiddenSubmissions::StorageError, 'Validation cannot write private choices'; end
      end
      def initialize(root, actor:, session_id:)
        @root, @actor, @session_id = root, actor, session_id
        @vault = HiddenSubmissions::Vault.new(Snapshot.new(root))
      end
      def prepare(session_id:, round_id:, user:, payload:, nonce: nil)
        target!(session_id, user)
        normalized = HiddenSubmissions::Commitment.normalize(payload)
        candidates = @root['entries'].values.flat_map { |entry| [entry.reject { |key, _| key == 'versions' }, *entry['versions'].values] }
        stored = candidates.find do |value|
          value['round_id'] == round_id && value['user'].downcase == @actor && value['payload'] == normalized &&
            (nonce.nil? || nonce == value['nonce'])
        end
        raise HiddenSubmissions::StorageError, 'Original private choice is missing' unless stored
        HiddenSubmissions::Envelope.new(**stored.transform_keys(&:to_sym))
      end
      def reveal(session_id:, round_id:, user:, commitment: nil)
        target!(session_id, user)
        @vault.reveal(session_id: session_id, round_id: round_id, user: user, commitment: commitment)
      end
      def verify(envelope)
        target!(envelope.session_id, envelope.user)
        @vault.verify(envelope)
      end
      def discard(**_target); false; end
      private
      def target!(session_id, user)
        unless session_id.eql?(@session_id) && Publication::Data.account(user).downcase == @actor
          raise HiddenSubmissions::StorageError, 'Wrong private validation scope'
        end
      end
    end
    class Storage
      def initialize(directory:, identity:, actor:, session_id:, guard:)
        @identity, @actor, @session_id = identity, actor, session_id
        @storage = LocalExecutionPlanStorage.new(directory: directory, guard: guard)
      end
      def read
        @storage.access(validate: method(:validate!)) do |document|
          LocalPrivateChoices.copy(document || empty)
        end
      rescue Publication::Invalid, IOError, SystemCallError => error
        raise HiddenSubmissions::StorageError, 'Cannot read private choices', cause: error
      end
      def update
        @storage.access(validate: method(:validate!)) do |document|
          document ||= empty
          yield document
          validate!(document)
          @storage.write(document)
          LocalPrivateChoices.copy(document)
        end
      rescue Publication::Invalid, IOError, SystemCallError => error
        raise HiddenSubmissions::StorageError, 'Private choice write needs readback', cause: error
      end
      private
      def empty; {'version' => 1, 'identity' => @identity, 'entries' => {}}; end
      def validate!(root)
        unless root.is_a?(Hash) && root.keys.sort == %w[version identity entries].sort &&
            root['version'].eql?(1) && root['identity'] == @identity && root['entries'].is_a?(Hash) && root['entries'].size <= 256
          raise HiddenSubmissions::StorageError, 'Invalid private choice storage'
        end
        root['entries'].each do |key, value|
          unless value.is_a?(Hash) && value.keys.sort == %w[session_id round_id user payload nonce commitment versions].sort &&
              value['versions'].is_a?(Hash) && value['versions'].size <= 32
            raise HiddenSubmissions::StorageError, 'Invalid private choice versions'
          end
          expected_key = Digest::SHA256.hexdigest([@session_id, value['round_id'], @actor].join("\0"))
          raise HiddenSubmissions::StorageError, 'Wrong private choice key' unless key == expected_key
          check_envelope!(value.reject { |name, _| name == 'versions' })
          value['versions'].each do |commitment, old|
            check_envelope!(old)
            unless commitment == old['commitment'] && old['round_id'] == value['round_id']
              raise HiddenSubmissions::StorageError, 'Wrong private choice version'
            end
          end
        end
      end
      def check_envelope!(value)
        unless value.is_a?(Hash) && value.keys.sort == %w[session_id round_id user payload nonce commitment].sort &&
            value['session_id'].eql?(@session_id) && value['user'].is_a?(String) && value['user'].downcase == @actor &&
            value['round_id'].is_a?(String) && value['round_id'].bytesize.between?(1, 256) &&
            value['nonce'].is_a?(String) && value['nonce'].match?(/\A[0-9a-f]{64}\z/) &&
            value['commitment'].is_a?(String) && value['commitment'].match?(/\A[0-9a-f]{64}\z/) &&
            HiddenSubmissions::Commitment.valid?(payload: value['payload'], nonce: value['nonce'], commitment: value['commitment'])
          raise HiddenSubmissions::StorageError, 'Invalid private choice envelope'
        end
      end
    end

    def initialize(directory:, context:, session_id:, scope_digest:)
      raise Publication::Invalid, :invalid_composition unless context.instance_of?(LocalReadinessSession::Context)
      raise Publication::Invalid, :invalid_session unless Data.integer?(session_id, 1)
      @context, @expected = context, Data.freeze_tree(Data.copy(context.call))
      @actor, @session_id = @expected.fetch('account'), session_id
      Data.text!(scope_digest, bytes: 256)
      @identity = self.class.identity(backend_identity: @expected['backend_identity'], scope_digest: scope_digest, actor: @actor, session_id: session_id)
      storage = Storage.new(directory: File.join(directory, 'private-inputs', @identity), identity: @identity,
        actor: @actor, session_id: session_id, guard: method(:guard!))
      @vault = HiddenSubmissions::Vault.new(storage)
    end
    def prepare(session_id:, round_id:, user:, payload:, nonce: nil)
      target!(session_id, user)
      @vault.prepare(session_id: session_id, round_id: round_id, user: user, payload: self.class.copy(payload), nonce: nonce)
    end
    def reveal(session_id:, round_id:, user:, commitment: nil)
      target!(session_id, user)
      @vault.reveal(session_id: session_id, round_id: round_id, user: user, commitment: commitment)
    end
    def discard(session_id:, round_id:, user:)
      target!(session_id, user)
      # Accepted local history still needs the original envelope for exact
      # replay validation. It remains in this actor's private archive.
      false
    end
    def verify(envelope)
      target!(envelope.session_id, envelope.user)
      @vault.verify(envelope)
    end
    private
    def guard!
      unless @context.call.eql?(@expected) && @expected['cancelled'].equal?(false)
        raise ReadinessContract::Blocked, :context_changed
      end
    end
    def target!(session_id, user)
      guard!
      unless session_id.eql?(@session_id) && Data.account(user).downcase == @actor
        raise ReadinessContract::Blocked, :private_choice_scope
      end
    end
  end
end
