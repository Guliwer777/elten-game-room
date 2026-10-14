# encoding: UTF-8
require_relative 'publication'

module GameRoomTournaments
  # Wyłącznie dane zgody na cel. Nawet poprawny DTO nie ustanawia seala,
  # rezerwacji ani prawa startu. Brak pól jest błędem, nie żądaniem defaults.
  class MatchBinding
    Data = Publication::Data
    Invalid = Publication::Invalid
    FIELDS = %w[contract_version scope seal_id seal_revision plan_id plan_revision
      match_id leg execution_generation roles_status role_policy_ref players observers
      game_id options reservation create native_uuid table_id].map(&:freeze).freeze
    SCOPE = %w[namespace backend_identity app_uuid tournament_id].map(&:freeze).freeze
    PERSON = %w[account username role seat team game_role].map(&:freeze).freeze

    def self.build(value, registry:)
      data = Data.copy(value)
      fields!(data, FIELDS)
      raise Invalid, :contract_version unless data['contract_version'].eql?(1)
      fields!(data['scope'], SCOPE)
      data['scope'].each_value { |text| Data.text!(text, bytes: 4096) }
      %w[seal_id seal_revision plan_id plan_revision match_id execution_generation role_policy_ref game_id].each do |key|
        Data.text!(data[key], bytes: 256)
      end
      unless Data.integer?(data['leg'], 1) && Data.integer?(data['table_id'], 1)
        raise Invalid, :invalid_identity
      end
      unless Data.text?(data['native_uuid']) && data['native_uuid'].match?(/\A[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z/)
        raise Invalid, :invalid_native_uuid
      end
      raise Invalid, :unassigned_roles unless data['roles_status'] == 'confirmed'
      people!(data)
      options!(data, registry)
      reservation!(data)
      fields!(data['create'], %w[operation_id proof_ref])
      data['create'].each_value { |text| Data.text!(text, bytes: 256) }
      new(Data.freeze_tree(data))
    end

    def self.fields!(value, fields)
      raise Invalid, :invalid_fields unless Hash === value && value.keys.sort == fields.sort
    end

    def self.people!(data)
      players, observers = data.values_at('players', 'observers')
      unless Array === players && Array === observers && players.size.between?(1, 256) && observers.size <= 256
        raise Invalid, :invalid_people
      end
      (players + observers).each do |person|
        fields!(person, PERSON)
        # Limit dotyczy surowej nazwy; downcase U+0130 może rozszerzyć account.
        username = Data.account(person['username'])
        raise Invalid, :invalid_account unless person['account'].eql?(username.downcase)
      end
      accounts = (players + observers).map { |person| person['account'] }
      raise Invalid, :duplicate_account unless accounts.uniq.size == accounts.size
      players.each do |person|
        unless person['role'] == 'player' && Data.integer?(person['seat']) && person['seat'] < players.size
          raise Invalid, :invalid_role
        end
        Data.text!(person['team'], bytes: 256) unless person['team'].nil?
        Data.text!(person['game_role'], bytes: 256)
        if person.values_at('team', 'game_role').any? { |value| %w[unassigned NIEUSTALONE].include?(value) }
          raise Invalid, :unassigned_roles
        end
      end
      unless players.map { |person| person['seat'] }.uniq.size == players.size
        raise Invalid, :duplicate_seat
      end
      unless observers.all? { |person| person['role'] == 'observer' && person.values_at('seat', 'team', 'game_role').all?(&:nil?) }
        raise Invalid, :invalid_observer
      end
    end

    def self.options!(data, registry)
      raise Invalid, :invalid_game unless data['game_id'].match?(/\A[a-z0-9_]+\z/)
      settings = { 'players_per_match' => data['players'].size, 'game_options' => data['options'] }
      # Reużycie walidatora typów/choices/gry bez zmiany przyjętego Publication.
      Publication.send(:validate_game, data['game_id'], settings, registry)
      unless settings['game_options'].eql?(data['options'])
        raise Invalid, :incomplete_game_options
      end
    end

    def self.reservation!(data)
      reservation = data['reservation']
      fields!(reservation, %w[id revision fencing ready_versions])
      %w[id revision].each { |key| Data.text!(reservation[key], bytes: 256) }
      raise Invalid, :invalid_fencing unless Data.integer?(reservation['fencing'], 1)
      ready = reservation['ready_versions']
      fields!(ready, data['players'].map { |person| person['account'] })
      ready.each_value { |revision| Data.text!(revision, bytes: 256) }
    end

    private_class_method :fields!, :people!, :options!, :reservation!

    def initialize(data)
      @data = data
      freeze
    end
    private_class_method :new

    def to_h
      @data
    end
  end
end
