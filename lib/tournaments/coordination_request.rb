# encoding: UTF-8
require_relative 'match_binding'
require_relative 'execution_plan_contract'
require 'digest'

module GameRoomTournaments
  # Dane przed utworzeniem stołu. Nie ustanawiają seala ani uprawnień.
  class CoordinationRequest
    Data = Publication::Data
    Invalid = Publication::Invalid
    FIELDS = (MatchBinding::FIELDS - %w[reservation create native_uuid table_id] + %w[window visibility]).freeze

    def self.fields!(value, names)
      raise Invalid, :invalid_fields unless value.is_a?(Hash) && value.keys.sort == names.sort
    end

    def self.from_execution_plan(evidence:, expected_source:, match_id:, leg:, window_id:, registry:)
      match_id = String.new(Data.text!(match_id, bytes: 256))
      window_id = String.new(Data.text!(window_id, bytes: 256))
      raise Invalid, :invalid_leg unless Data.integer?(leg, 1)
      evidence = ExecutionPlanContract.validate(evidence, expected_source, registry: registry)
      match = evidence['plan']['matches'].find { |item| item['match_id'].eql?(match_id) && item['leg'].eql?(leg) }
      window = match && match['windows'].find { |item| item['id'].eql?(window_id) }
      raise Invalid, :brak_wyboru unless window
      build(ExecutionPlanContract.payload(evidence, match, window), registry: registry)
    end

    def self.build(value, registry:)
      data = Data.copy(value)
      fields!(data, FIELDS)
      raise Invalid, :contract_version unless data['contract_version'].eql?(1)
      fields!(data['scope'], MatchBinding::SCOPE)
      data['scope'].each_value { |v| Data.text!(v, bytes: 4096) }
      %w[seal_id seal_revision plan_id plan_revision match_id execution_generation role_policy_ref game_id].each do |key|
        Data.text!(data[key], bytes: 256)
      end
      raise Invalid, :invalid_leg unless Data.integer?(data['leg'], 1)
      raise Invalid, :unassigned_roles unless data['roles_status'] == 'confirmed'
      raise Invalid, :invalid_visibility unless data['visibility'] == 'private'
      people!(data)
      options!(data, registry)
      window!(data['window'])
      new(Data.freeze_tree(data))
    end

    def self.people!(data)
      players, observers = data.values_at('players', 'observers')
      unless players.is_a?(Array) && players.size.between?(1,256) && observers.is_a?(Array) && observers.size <= 256
        raise Invalid, :invalid_people
      end
      (players + observers).each do |p|
        fields!(p, MatchBinding::PERSON)
        raise Invalid, :invalid_account unless p['account'].eql?(Data.account(p['username']).downcase)
      end
      accounts = (players + observers).map { |p| p['account'] }
      raise Invalid, :duplicate_account unless accounts.uniq.size == accounts.size
      players.each do |p|
        unless p['role'] == 'player' && Data.integer?(p['seat']) && p['seat'] < players.size
          raise Invalid, :invalid_role
        end
        Data.text!(p['team'], bytes: 256) unless p['team'].nil?
        Data.text!(p['game_role'], bytes: 256)
        raise Invalid, :unassigned_roles if p.values_at('team','game_role').any? { |v| %w[unassigned NIEUSTALONE].include?(v) }
      end
      raise Invalid, :duplicate_seat unless players.map { |p| p['seat'] }.uniq.size == players.size
      unless observers.all? { |p| p['role'] == 'observer' && p.values_at('seat','team','game_role').all?(&:nil?) }
        raise Invalid, :invalid_observer
      end
    end

    def self.options!(data, registry)
      raise Invalid, :invalid_game unless data['game_id'].match?(/\A[a-z0-9_]+\z/)
      settings = {'players_per_match'=>data['players'].size, 'game_options'=>data['options']}
      # Ten sam walidator co MatchBinding; porównanie eql? zabrania defaults i konwersji.
      Publication.send(:validate_game, data['game_id'], settings, registry)
      raise Invalid, :incomplete_game_options unless settings['game_options'].eql?(data['options'])
    end

    def self.window!(window)
      fields!(window, %w[id opens closes policy_ref])
      %w[id policy_ref].each { |k| Data.text!(window[k], bytes: 256) }
      unless Data.integer?(window['opens']) && Data.integer?(window['closes']) && window['opens'] < window['closes']
        raise Invalid, :invalid_window
      end
    end

    def initialize(data)
      @data = data
      freeze
    end
    private_class_method :new, :people!, :options!

    def to_h
      @data
    end

    def digest
      Digest::SHA256.hexdigest(JSON.generate(@data))
    end
  end
end
