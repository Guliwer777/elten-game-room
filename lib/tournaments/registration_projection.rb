# encoding: UTF-8
require_relative 'publication'
require_relative 'local_registration_time'

module GameRoomTournaments
  # Projekcja dopisywanych join. Nie wykonuje sieci ani nie wymaga organizatora online.
  class RegistrationProjection
    Data = Publication::Data
    Invalid = Publication::Invalid
    Incomplete = Publication::Incomplete

    # Bez nicku, lokalnego czasu lub ID wiersza. Stabilny klucz przechowuje
    # wywołujący także po utracie odpowiedzi; nie jest to serwerowe UNIQUE.
    def self.join_values(tournament_id:, operation_key:)
      raise Invalid, :invalid_tournament_id unless Data.integer?(tournament_id, 1)
      Data.key!(operation_key)
      Data.freeze_tree({ 'tournament_id' => tournament_id,
        'operation_key' => String.new(operation_key), 'kind' => 'join' })
    end

    def self.withdrawal_values(tournament_id:, operation_key:)
      Data.freeze_tree(join_values(tournament_id: tournament_id, operation_key: operation_key).merge('kind' => 'withdrawal'))
    end

    def self.local_start(row)
      TournamentTiming.starts_at(row)
    rescue LocalRegistrationTime::Invalid => error
      raise Invalid, error.code
    end

    def self.build(announcements:, registrations:, registry:, complete:)
      publications = Publication.project(rows: announcements, registry: registry, complete: complete)
      new(publications, registrations, complete, registry)
    end

    def initialize(publications, registrations, complete, registry)
      @registry = registry
      @by_id = {}
      publications['announcements'].each do |row|
        row['alias_ids'].each do |id|
          raise Invalid, :alias_conflict if @by_id.key?(id)
          @by_id[id] = row
        end
      end
      entries = Data.entries(registrations, complete: complete, key_name: 'operation_key') { |row| decode(row) }
      groups, diagnostics = Data.reconcile(entries) { |row| [row['canonical_tournament_id'], row['kind']] }
      published = lifecycle(publications['announcements'], groups.flatten)
      operations, accepted = reduce_groups(groups, diagnostics)
      # Retention uses authenticated accepted operations, not arbitrary writes
      # or the time at which somebody happens to open a tournament.
      @activity = accepted.group_by { |row| [row['canonical_tournament_id'], row['__insertion_user'].downcase, row['operation_key']] }.
        values.map { |rows| rows.min_by { |row| row['__id'] } }.group_by { |row| row['canonical_tournament_id'] }
      Data.freeze_tree(@activity)
      Data.freeze_tree(@versions)
      @pairing_ids = accepted.select { |row| row['kind'] == 'pairing' }.map { |row| row['canonical_tournament_id'] }.uniq.freeze
      data = { 'announcements' => published,
        'members' => members(accepted), 'operations' => operations,
        'diagnostics' => { 'announcements' => publications['diagnostics'],
          'registrations' => diagnostics.uniq.sort_by { |item| JSON.generate(item) } } }
      unless @pairing_ids.empty?
        @pair_requests=[]
        data['pairs'] = pairs(accepted)
        data['pair_requests']=@pair_requests
      end
      @data = Data.freeze_tree(data)
      @by_id.freeze
      freeze
    end
    private_class_method :new

    def operation_status(tournament_id:, account:, operation_key:)
      raise Invalid, :invalid_tournament_id unless Data.integer?(tournament_id, 1)
      name = Data.account(account).downcase
      Data.key!(operation_key)
      conflict = @data['diagnostics']['registrations'].any? do |item|
        item['code'] == 'key_conflict' && item['account'] == name && item['key'] == operation_key
      end
      return 'conflict' if conflict
      tournament = @by_id[tournament_id]
      return 'unconfirmed' unless tournament
      operation = @data['operations'].find do |item|
        item['tournament_id'] == tournament['__id'] && item['account'] == name && item['operation_key'] == operation_key
      end
      operation ? operation['status'] : 'unconfirmed'
    end

    def to_h
      @data
    end

    def pairing_used?(id)
      @pairing_ids.include?(id)
    end

    def retention_history(id)
      versions = @versions.fetch(id)
      changes = versions.drop(1).to_h { |position, row| [position, row] }
      events = (@activity[id] || []).map do |event|
        position = event.values_at('__insertion_time', '__id')
        {time: position.first, id: position.last, publication: changes[position]}
      end
      {publication: versions.first.last, events: events}
    end

    # Keep the exact validated projection type and its reconciliation evidence.
    # Expiry removes access to a tournament, not the immutable operation log.
    def with_retained_announcements(rows)
      ids = rows.to_h { |row| [row.fetch('__id'), true] }
      data = @data.merge('announcements' => rows)
      %w[members pairs pair_requests].each do |key|
        data[key] = data[key].select { |row| ids[row['tournament_id']] } if data[key]
      end
      copy = dup
      copy.instance_variable_set(:@data, Data.freeze_tree(data))
      copy.freeze
    end

    private

    def decode(row)
      metadata = Data.metadata(row)
      raise Invalid, :unsupported_kind unless %w[join withdrawal removal pairing amendment cancellation].include?(row['kind'])
      values = self.class.join_values(tournament_id: row['tournament_id'], operation_key: row['operation_key']).merge('kind' => row['kind'])
      tournament = @by_id[row['tournament_id']]
      raise Invalid, :unknown_tournament unless tournament
      if row['kind'] == 'removal'
        raise Invalid, :not_organizer unless metadata['__insertion_user'].downcase == tournament['__insertion_user'].downcase
        values['account'] = Data.account(row['account']).downcase
      end
      if row['kind'] == 'pairing'
        values['account'] = Data.account(row['account']).downcase
        values['partner'] = row['partner'].nil? ? nil : Data.account(row['partner']).downcase
        raise Invalid, :invalid_partner if values['account'] == values['partner']
        unless metadata['__insertion_user'].downcase == values['account'] || metadata['__insertion_user'].downcase == tournament['__insertion_user'].downcase
          raise Invalid, :not_organizer
        end
        Data.key!(row['pairing_generation'])
        values['pairing_generation'] = row['pairing_generation']
      end
      if %w[amendment cancellation].include?(row['kind'])
        raise Invalid, :not_organizer unless metadata['__insertion_user'].downcase == tournament['__insertion_user'].downcase
        Data.key!(row['publication_generation'])
        values['publication_generation'] = row['publication_generation']
        if row['kind'] == 'amendment'
          revised = StrictJson.parse(row['amendment_json'], max_nesting: 8)
          raise Invalid, :invalid_amendment unless revised.is_a?(Hash) && revised.keys.sort == Publication::COLUMNS.sort && revised['publication_key'] == tournament['publication_key']
          checked = Publication.project(rows: [revised.merge(tournament.slice('__id', '__insertion_time', '__insertion_user'))], registry: @registry, complete: true)
          raise Invalid, :invalid_amendment unless checked['diagnostics'].empty? && checked['announcements'].size == 1
          values['amendment_json'] = JSON.generate(revised)
        end
      end
      values.merge(metadata).merge('canonical_tournament_id' => tournament['__id'])
    end

    def reduce_groups(groups, diagnostics)
      accepted = []
      operations = groups.map do |group|
        first = group.min_by { |row| row['__id'] }
        tournament = @by_id[first['tournament_id']]
        eligible = group.select do |row|
          tournament = publication_at(row)
          time = row['__insertion_time']
          creator = row['__insertion_user'].downcase == tournament['__insertion_user'].downcase && time >= tournament['__insertion_time']
          if %w[amendment cancellation].include?(row['kind'])
            @applied_changes.include?(row['__id'])
          elsif %w[withdrawal removal pairing].include?(row['kind'])
            (TournamentTiming.registration_open?(tournament,time) || creator || TournamentTiming.registration_closed?(tournament,time)) && !TournamentTiming.started?(tournament,time) && !cancelled_at?(row)
          else
            (TournamentTiming.registration_open?(tournament,time) || creator) && !TournamentTiming.registration_closed?(tournament,time) && !cancelled_at?(row)
          end
        end
        (group - eligible).each do |row|
          diagnostics << { 'code' => 'outside_window', 'ids' => [row['__id']],
            'account' => row['__insertion_user'].downcase, 'key' => row['operation_key'] }
        end
        accepted.concat(eligible)
        { 'tournament_id' => tournament['__id'], 'account' => first['__insertion_user'].downcase,
          'operation_key' => first['operation_key'], 'status' => eligible.empty? ? 'outside_window' : 'confirmed',
          'record_ids' => group.map { |row| row['__id'] }.sort,
          'eligible_ids' => eligible.map { |row| row['__id'] }.sort }
      end.sort_by { |item| [item['tournament_id'], item['account'], item['operation_key']] }
      [operations, accepted]
    end

    def members(accepted)
      accepted = accepted.select { |row| %w[join withdrawal removal].include?(row['kind']) }
      # Czas i ID są wyłącznie deterministycznym wyborem dowodu tego konta.
      # Nie definiują kolejki miejsc, limitu, punktacji ani pierwszeństwa awansu.
      accepted.group_by { |row| [row['canonical_tournament_id'], row['kind'] == 'removal' ? row['account'] : row['__insertion_user'].downcase] }.map do |key, rows|
        last = rows.max_by { |row| [row['__insertion_time'], row['__id']] }
        next if %w[withdrawal removal].include?(last['kind'])
        departure = rows.select { |row| %w[withdrawal removal].include?(row['kind']) }.max_by { |row| [row['__insertion_time'], row['__id']] }
        rows = rows.select { |row| row['kind'] == 'join' }
        rows = rows.select { |row| ([row['__insertion_time'], row['__id']] <=> [departure['__insertion_time'], departure['__id']]) == 1 } if departure
        first = rows.min_by { |row| [row['__insertion_time'], row['__id']] }
        { 'tournament_id' => key[0], 'account' => key[1], 'username' => first['__insertion_user'],
          'registration_id' => first['__id'], 'joined_at' => first['__insertion_time'] }
      end.compact.sort_by { |item| [item['tournament_id'], item['account']] }
    end

    def pairs(accepted)
      accepted.group_by { |row| row['canonical_tournament_id'] }.flat_map do |id, rows|
        active, links, requests = {}, {}, {}
        rows.sort_by { |row| [row['__insertion_time'], row['__id']] }.each do |row|
          account = row['kind'] == 'removal' || row['kind'] == 'pairing' ? row['account'] : row['__insertion_user'].downcase
          case row['kind']
          when 'join' then active[account] = true
          when 'withdrawal', 'removal'
            active.delete(account)
            links.delete(links.delete(account))
            requests.delete_if{|from,to|from==account || to==account}
          when 'pairing'
            current = self.class.pairing_generation(active.keys, links)
            next unless current == row['pairing_generation'] && active[account] && (row['partner'].nil? || active[row['partner']])
            partner = row['partner']
            organizer = row['__insertion_user'].downcase == @by_id[id]['__insertion_user'].downcase
            next if !organizer && partner && links[partner] && links[partner] != account
            links.delete(links.delete(account))
            requests.delete(account)
            if partner && (organizer && row['__insertion_user'].downcase!=account || requests[partner]==account)
              links.delete(links.delete(partner))
              links[account], links[partner] = partner, account
              requests.delete_if{|from,to|[account,partner].include?(from) || [account,partner].include?(to)}
            elsif partner
              requests[account]=partner
            else
              requests.delete_if{|_,to|to==account}
            end
          end
        end
        requests.each{|from,to|@pair_requests<<{'tournament_id'=>id,'from'=>from,'to'=>to}}
        links.select { |a, b| a < b }.map { |a, b| {'tournament_id' => id, 'accounts' => [a, b]} }
      end.sort_by { |row| [row['tournament_id'], row['accounts']] }
    end

    def self.pairing_generation(accounts, links)
      require 'digest'
      Digest::SHA256.hexdigest(JSON.generate([accounts.sort, links.select { |a, b| a < b }.sort]))
    end

    def self.publication_generation(row)
      require 'digest'
      Digest::SHA256.hexdigest(JSON.generate(Publication::COLUMNS.to_h { |column| [column, row[column]] }))
    end

    def lifecycle(announcements, accepted)
      @versions, @cancelled, @applied_changes = {}, {}, []
      announcements.filter_map do |original|
        current, cancelled = original, false
        @versions[original['__id']] = [[nil, original]]
        accepted.select { |row| row['canonical_tournament_id'] == original['__id'] && %w[amendment cancellation].include?(row['kind']) }.sort_by { |row| [row['__insertion_time'], row['__id']] }.each do |action|
          next if cancelled || action['publication_generation'] != self.class.publication_generation(current)
          next if action['kind'] != 'cancellation' && TournamentTiming.started?(current,action['__insertion_time'])
          if action['kind'] == 'cancellation'
            cancelled = true
            @cancelled[original['__id']] = [action['__insertion_time'],action['__id']]
          else
            revised = StrictJson.parse(action['amendment_json'], max_nesting: 8)
            # A manual Start records its instant before the server write.
            # Historical membership is evaluated against the version that
            # existed when each registration was inserted, not this final one.
            next if !TournamentTiming.optional?(revised) && TournamentTiming.started?(revised,action['__insertion_time'])
            current = revised.merge(current.slice('__id', '__insertion_time', '__insertion_user', 'alias_ids'))
          end
          @applied_changes << action['__id']
          @versions[original['__id']] << [[action['__insertion_time'],action['__id']],current]
        end
        original['alias_ids'].each { |id| @by_id[id] = current }
        cancelled ? nil : current
      end
    end

    def publication_at(action)
      position=[action['__insertion_time'],action['__id']]
      @versions.fetch(action['canonical_tournament_id']).reverse.find{|key,_|key.nil? || (key<=>position)<=0}.last
    end

    def cancelled_at?(action)
      key=@cancelled[action['canonical_tournament_id']]
      key && (key<=>[action['__insertion_time'],action['__id']])<=0
    end
  end
end
