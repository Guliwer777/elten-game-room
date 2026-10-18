# encoding: UTF-8
require_relative 'coordination_contract'

module GameRoomTournaments
  # Własna zgoda i membership w tym samym atomowym lokalnym commit co cel.
  # Nie jest logowaniem konta sieciowego ani wejściem do zwykłego lobby.
  class LocalFixedTeamAdmission
    C = CoordinationContract
    Data = Publication::Data
    FIELDS = %w[version kind id account binding_digest epoch native_uuid table_id seat team created_at].freeze
    ENTRY_FIELDS = (FIELDS + %w[consent_id participant_id membership_generation status]).freeze

    def self.validate!(execution, core)
      admission = execution['admission']
      admission = {'consents' => {}, 'entries' => {}} if admission.nil?
      C.fields!(admission, %w[consents entries])
      unless admission.values.all? { |rows| rows.is_a?(Hash) && rows.size <= execution['request']['players'].size }
        raise Publication::Invalid, :sandbox_corrupt
      end
      target = execution['target']
      if !target
        raise Publication::Invalid, :sandbox_corrupt unless admission.values.all?(&:empty?)
        return
      end
      binding = target['binding']
      people = execution['request']['players']
      ids = []
      admission.each do |kind, rows|
        rows.each do |account, receipt|
          C.fields!(receipt, kind == 'consents' ? FIELDS : ENTRY_FIELDS)
          person = people.find { |p| p['account'] == account }
          expected = {'version' => 1, 'kind' => kind == 'consents' ? 'consent' : 'entry',
            'account' => account, 'binding_digest' => C.digest(binding),
            'native_uuid' => binding['native_uuid'], 'table_id' => binding['table_id'],
            'seat' => person && person['seat'], 'team' => person && person['team']}
          unless person && expected.all? { |key, value| receipt[key].eql?(value) } &&
              Data.integer?(receipt['epoch'], 1) && receipt['epoch'] <= execution['epoch'] &&
              receipt['epoch'] == execution['operations']['create_bind']['operation']['preconditions']['grant']['fencing'] &&
              Data.integer?(receipt['created_at']) && receipt['created_at'] >= execution['request']['window']['opens'] &&
              receipt['created_at'] < execution['expires_at']
            raise Publication::Invalid, :sandbox_corrupt
          end
          Data.text!(receipt['id'], bytes: 256)
          raise Publication::Invalid, :sandbox_corrupt if ids.include?(receipt['id'])
          ids << receipt['id']
          next if kind == 'consents'
          consent = admission['consents'][account]
          participant = core && core['participants'][account]
          initial = target['readback']['participants'][account]
          unless consent && consent['id'] == receipt['consent_id'] && consent['epoch'] == receipt['epoch'] &&
              consent['created_at'] <= receipt['created_at'] && participant &&
              participant.eql?({'id' => receipt['participant_id'], 'user' => person['username']}) &&
              receipt['status'] == (initial ? 'already_here' : 'joined') &&
              (!initial || participant.eql?(initial))
            raise Publication::Invalid, :sandbox_corrupt
          end
          Data.text!(receipt['participant_id'], bytes: 256)
          Data.text!(receipt['membership_generation'], bytes: 256)
        end
      end
      expected_people = Data.copy(target['readback']['participants'])
      admission['entries'].each do |account, receipt|
        person = people.find { |p| p['account'] == account }
        expected_people[account] = {'id' => receipt['participant_id'], 'user' => person['username']}
      end
      unless core && core['participants'].eql?(expected_people) &&
          core['participants'].values.map { |p| p['id'] }.uniq.size == core['participants'].size
        raise Publication::Invalid, :sandbox_corrupt
      end
    end

    def initialize(port:, storage:, request:, context:, record_reader:, clock:)
      @port, @storage, @request, @context, @record_reader, @clock = port, storage, request.to_h, context, record_reader, clock
      @key = C.digest(@request.values_at('scope', 'match_id', 'leg', 'execution_generation'))
    end

    def status
      @port.transaction do |document|
        execution = execution!(document)
        admission = execution['admission'] || {'consents' => {}, 'entries' => {}}
        account = actor
        detached({'consent' => admission['consents'][account], 'entry' => admission['entries'][account],
          'participants' => core!(document, execution)['participants'], 'binding' => execution['target']['binding'],
          'entered_accounts' => admission['entries'].keys.sort, 'current' => active?(execution), 'mode' => 'local_test'})
      end
    end

    def consent(binding_digest:)
      Data.text!(binding_digest, bytes: 256)
      mutate do |document, execution, admission, core|
        raise C::Blocked, :target_changed unless binding_digest == C.digest(execution['target']['binding'])
        prior = admission['consents'][actor]
        next prior if prior
        receipt = base(execution, 'consent')
        admission['consents'][actor] = receipt
        @storage.write(document, receipt: receipt)
        receipt
      end
    end

    def enter(consent_id:)
      Data.text!(consent_id, bytes: 256)
      mutate do |document, execution, admission, core|
        own = admission['consents'][actor]
        raise C::Blocked, :consent_required unless own && own['id'] == consent_id && own['epoch'] == execution['epoch']
        prior = admission['entries'][actor]
        next prior if prior
        person = @request['players'].find { |p| p['account'] == actor }
        existing = core['participants'][actor]
        participant = existing || {'id' => SecureRandom.uuid, 'user' => person.fetch('username')}
        receipt = base(execution, 'entry').merge('consent_id' => own['id'],
          'participant_id' => participant['id'], 'membership_generation' => SecureRandom.uuid,
          'status' => existing ? 'already_here' : 'joined')
        core['participants'][actor] = participant
        core['discovery_metadata']['player_count'] = core['participants'].size
        admission['entries'][actor] = receipt
        @storage.write(document, receipt: receipt)
        receipt
      end
    end

    private

    def detached(value)
      Data.freeze_tree(C.copy(value))
    end

    def actor
      account = @context.call.fetch('account')
      raise C::Blocked, :not_participant unless @request['players'].any? { |p| p['account'] == account }
      account
    end

    def execution!(document)
      execution = document['executions'][@key]
      unless execution && execution['request'].eql?(@request) && execution['target']
        raise C::Blocked, :target_not_prepared
      end
      actor
      execution
    end

    def core!(document, execution)
      uuid = execution['target']['binding']['native_uuid']
      core = document['native']['cores'].find { |row| row['id'] == uuid && (!row['closed'] || execution['result']) }
      raise C::Blocked, :native_target_missing unless core
      core
    end

    def active?(execution)
      grant = execution['grant']
      now = @clock.call
      raise C::Blocked, :invalid_clock unless Data.integer?(now)
      grant && grant['fencing'] == execution['epoch'] && grant['expires_at'] > now &&
        @request['window']['opens'] <= now && now < @request['window']['closes'] ? true : false
    end

    def mutate
      @record_reader.call(true)
      @port.transaction do |document|
        @record_reader.call(true)
        execution = execution!(document)
        raise C::Blocked, :stale_grant unless active?(execution)
        core = core!(document, execution)
        admission = execution['admission'] ||= {'consents' => {}, 'entries' => {}}
        result = yield document, execution, admission, core
        detached(result)
      end
    end

    def base(execution, kind)
      binding = execution['target']['binding']
      person = @request['players'].find { |p| p['account'] == actor }
      {'version' => 1, 'kind' => kind, 'id' => SecureRandom.uuid, 'account' => actor,
        'binding_digest' => C.digest(binding), 'epoch' => execution['epoch'],
        'native_uuid' => binding['native_uuid'], 'table_id' => binding['table_id'],
        'seat' => person['seat'], 'team' => person['team'], 'created_at' => @clock.call}
    end
  end
end
