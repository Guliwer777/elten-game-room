# encoding: UTF-8
require 'thread'
require_relative 'server_plan_archive'
require_relative 'ordinary_match_results'
require_relative 'standings_ranking'
require_relative 'group_standings'
require_relative 'match_order'
require_relative 'ordinary_team_players'
require_relative 'knockout_standings'
require_relative 'ordinary_match_forfeit'
require_relative 'ordinary_saved_match'

module GameRoomTournaments
  # Explicit ordinary-table test path, separate from global automatic dispatch.
  # One designated creator (first planned player), first native game only.
  class OrdinaryMatchService
    include OrdinaryMatchForfeit
    include OrdinarySavedMatch
    class Blocked < StandardError
      attr_reader :code
      def initialize(code); @code = code; super(code.to_s); end
    end
    Data = Publication::Data
    attr_reader :owner
    def initialize(program:, registry:, lobby:, games:, transport:, table:, journal:, source:, user:)
      @program, @registry, @lobby, @games, @transport = program, registry, lobby, games, transport
      @table, @journal, @source, @user = table, journal, source, user
      @owner = journal.owner
      @changed = false
      @bindings, @seen, @errors = {}, {}, Queue.new
      @jobs, @lock, @closed = Queue.new, Mutex.new, false
      account!
    end

    def open_match(match_id:, leg:)
      candidate, id = source!
      match = candidate.fetch('matches').find { |m| m['match_id'] == match_id && m['leg'] == leg }
      raise Blocked, :missing_match unless match
      raise Blocked,:result_already_recorded if forfeit_document(candidate,id,match)
      raise Blocked, :unsupported_match_players unless supported_match?(candidate,match)
      raise Blocked, :not_a_match_player unless match['players'].include?(@owner)
      raise Blocked,:private_game_not_supported if @registry.build(candidate['game_id']).private_table_required?(candidate['game_options'])
      prepared=prepared_match(candidate,match)
      creator = prepared['players'].first['account']
      anchor = anchor(candidate, id, match, 'binding')
      binding = read_match_binding(candidate,id,match,creator)
      unless binding
        raise Blocked, :waiting_for_match_creator unless creator == @owner
        descriptor = {'kind'=>'ordinary-match-create-v1', 'schedule_id'=>candidate['schedule_id'], 'match_id'=>match_id, 'leg'=>leg,
          'publication_ref'=>candidate.fetch('publication_ref')}
        create_anchor = anchor(candidate, id, match, 'create')
        values = create_anchor.merge('kind'=>'plan_document','document_json'=>JSON.generate(descriptor))
        record = @journal.prepare(kind:'plan_document', intent_id:'ordinary-create:'+create_anchor['operation_key'], values:values)
        account!
        suffix=' / '+leg.to_s+' ['+create_anchor['operation_key'][0,12]+']'
        names=prepared['players'].map{|person|person['account'][0,14]}.join(' — ')
        name=names[0,LobbyRepository::TABLE_NAME_MAX_LENGTH-suffix.length].rstrip+suffix
        room = @lobby.current_table_for(@user.call)
        if room
          raise Blocked, :already_at_another_table unless room['name'] == name && room['game'] == candidate['game_id'] && room['owner'].downcase == @owner
        else
          raise Blocked, :creation_unconfirmed unless record['status'] == 'prepared'
          raise Blocked, :creation_unconfirmed unless @journal.claim(record['id'])
          current, current_id = source!
          raise Blocked, :source_changed unless current == candidate && current_id == id
          created = @lobby.create_table(name:name, game:candidate['game_id'], owner:@user.call,
            game_options:JSON.generate(prepared['options']), private_table:false)
          raise Blocked, :already_at_another_table unless created && created.created?
          room = created.table
        end
        account!
        raise Blocked, :table_already_has_games unless @transport.game_sessions(room, force:true).empty?
        binding = {'kind'=>'ordinary-match-binding-v1','schedule_id'=>candidate['schedule_id'],'match_id'=>match_id,'leg'=>leg,
          'session_id'=>SecureRandom.random_number(2_000_000_000)+1,
          'creator'=>creator,'game_id'=>candidate['game_id'],'options'=>prepared['options'],
          'table'=>room.slice('__id','__live_session_id','name','game','owner','game_options'),
          'players'=>prepared['players']}
        binding['publication_ref']=candidate.fetch('publication_ref')
        previous=@journal.find(kind:'plan_document',intent_id:'ordinary-document:'+anchor['operation_key'])
        binding=StrictJson.parse(previous['values']['document_json'],max_nesting:12) if previous
        publish_document(binding, anchor) do |document|
          current,current_id=source!
          current==candidate && current_id==id && valid_binding?(document,candidate,match)
        end
        pending=@journal.fetch(record['id'])
        if pending['status']!='confirmed'
          @journal.resolve(pending['id'],status:'confirmed',evidence:{'table_id'=>room['__id'],'native_session_id'=>room['__live_session_id']},expected_revision:pending['revision'])
        end
      end
      raise Blocked, :wrong_match_binding unless valid_binding?(binding, candidate, match)
      room = binding.fetch('table')
      if creator != @owner
        joined = @lobby.join_table(room, @user.call)
        raise Blocked, :table_join_failed unless joined && [:joined,:already_here].include?(joined.status)
        room = joined.table
      end
      account!
      @lock.synchronize { @bindings[room['__id']] = [Data.freeze_tree(Data.copy(binding)), candidate, id, match] }
      start_worker
      room
    end

    # Only an event handoff inside the existing runner's observation boundary.
    # Repository/server I/O happens later, on this separate finite-work consumer.
    def start_parameters(table, players: nil, options: nil)
      row=@lock.synchronize{@bindings[table['__id']]}
      return {} unless row && row[0]['table']['__live_session_id']==table['__live_session_id']
      account!
      binding,candidate,id,match=row
      raise Blocked,:result_already_recorded if forfeit_document(candidate,id,match)
      raise Blocked,:not_a_match_player unless binding['creator']==@owner
      current,current_id=source!
      raise Blocked,:source_changed unless current==candidate && current_id==id
      actual_options=options || StrictJson.parse(table.fetch('game_options'),max_nesting:12)
      normalized=@registry.build(binding['game_id']).normalize_options(actual_options)
      team=binding['players'].any?{|person|person.key?('team')}
      equal=team ? normalized.reject{|key,_|key=='team_players'}==binding['options'].reject{|key,_|key=='team_players'} : normalized==binding['options']
      raise Blocked,:wrong_game_options unless equal
      if players
        raise Blocked,:wrong_game_players unless players.map{|name|Data.account(name).downcase}.sort==binding['players'].map{|p|p['account']}.sort
      end
      raise Blocked,:match_already_has_a_game unless @transport.game_sessions(table,force:true).empty?
      ordered = binding['players'].sort_by{|person|person['seat']}.map do |person|
        (players || []).find{|name|Data.account(name).downcase==person['account']} || person['username']
      end
      result={requested_session_id:binding.fetch('session_id'), players:ordered}
      if team
        result[:options]=JSON.generate(@registry.build(binding['game_id']).with_team_assignment(binding['options'],players:ordered,seats:binding['options'].fetch('team_seats')))
      end
      result
    end

    def observe(table, session, replay, events=nil)
      return unless replay.finished? && session && table
      @lock.synchronize do
        row = @bindings[table['__id']]
        return unless row && row[0]['creator'] == @owner && !@closed
        return unless row[0]['table']['__live_session_id']==table['__live_session_id']
        return unless session['__id']==row[0]['session_id']
        key = [table['__id'], row[0]['match_id'], row[0]['leg']]
        return if @seen[key]
        raise Blocked, :result_queue_limit if @jobs.size >= 64
        capture=events && OrdinaryMatchResults.capture(registry:@registry,binding:row[0],session:session,replay:replay,events:events)
        @jobs << (capture ? row+[capture] : row)
        @seen[key] = true
      end
      true
    rescue Publication::Invalid=>error
      @errors << error if @errors.size<16
      false
    end

    def result_view(include_match_status:false)
      candidate, id = source!
      raise Blocked,:too_many_matches_for_test if candidate['matches'].size>64
      wanted=candidate['matches'].flat_map{|m|%w[binding result forfeit].map{|kind|anchor(candidate,id,m,kind)['operation_key']}}
      account!
      rows=@table.select(where:{'operation_key'=>{'in'=>wanted}},limit:1000).to_a
      account!
      raise Blocked,:result_read_limit if rows.size>=1000
      rows=Data.copy(rows,max_bytes:8_388_608,max_nodes:65_536,max_depth:12)
      grouped=rows.group_by{|row|row.fetch('operation_key')}
      read=->(key,creator){entries=grouped[key['operation_key']]; entries ? ServerPlanDocument.decode(entries,anchor:key,author:creator) : nil}
      results = []
      result_times=[]
      forfeitable=[]
      cancellable=[]
      candidate.fetch('matches').each do |match|
        next unless supported_match?(candidate,match)
        creator=prepared_match(candidate,match)['players'].first['account']
        forfeit=read.call(anchor(candidate,id,match,'forfeit'),candidate.fetch('publication_ref').fetch('author').downcase)
        if forfeit
          validate_forfeit!(forfeit,candidate,match)
          if forfeit['kind']=='ordinary-match-cancel-forfeit-v1'
            binding=read_match_binding(candidate,id,match,creator,initial:read.call(anchor(candidate,id,match,'binding'),creator))
            raise Blocked,:wrong_match_binding unless cancellation_valid_binding?(forfeit,binding,candidate,match)
            # Explicit organizer cancellation is the sporting cutoff. Native
            # history remains untouched; any later ordinary receipt is excluded.
          else
            raise Blocked,:conflicting_match_results if read.call(anchor(candidate,id,match,'result'),creator)
          end
          results << forfeit
          result_times.concat((grouped[anchor(candidate,id,match,'forfeit')['operation_key']] || []).filter_map{|row|row['__insertion_time'] if Data.integer?(row['__insertion_time'])})
          next
        end
        initial=read.call(anchor(candidate,id,match,'binding'),creator)
        binding = initial && read_match_binding(candidate,id,match,creator,initial:initial)
        unless binding
          forfeitable << {'match_id'=>match['match_id'],'leg'=>match['leg']} if include_match_status
          next
        end
        raise Blocked, :wrong_match_binding unless valid_binding?(binding,candidate,match)
        receipt = read.call(anchor(candidate,id,match,'result'), creator)
        unless receipt
          if include_match_status && @transport && @transport.game_sessions(binding['table'],force:true).empty?
            forfeitable << {'match_id'=>match['match_id'],'leg'=>match['leg']}
          elsif include_match_status && @games
            begin
              cancellation_boundary(binding)
              cancellable << {'match_id'=>match['match_id'],'leg'=>match['leg']}
            rescue Blocked=>error
              raise unless error.code==:result_already_recorded
            end
          end
          next
        end
        unless receipt['kind']=='ordinary-match-result-v1' && receipt['binding_digest']==Digest::SHA256.hexdigest(JSON.generate(binding)) &&
            receipt['match_id']==match['match_id'] && receipt['leg']==match['leg'] &&
            receipt['session_id']==binding['session_id'] && receipt['history_digest'].is_a?(String) &&
            /\A[0-9a-f]{64}\z/.match?(receipt['history_digest']) && receipt['summary'].is_a?(Hash) &&
            valid_summary?(receipt['summary'],match)
          raise Blocked, :invalid_result_receipt
        end
        results << receipt
        result_times.concat((grouped[anchor(candidate,id,match,'result')['operation_key']] || []).filter_map{|row|row['__insertion_time'] if Data.integer?(row['__insertion_time'])})
      end
      normalized = results.map { |r| r['summary'].slice('participants','winners','scores','score_order').merge('id'=>JSON.generate([r['match_id'],r['leg']])) }
      team=candidate.key?('membership')
      units=team ? candidate['membership']['units'].map{|unit|unit['unit_id']} : candidate.fetch('roster')
      knockout=nil
      standings = if candidate['format']=='knockout'
        knockout=KnockoutStandings.calculate(candidate:candidate,units:units,results:normalized,unit_key:team ? 'unit_ids' : 'players')
        knockout['standings']
      elsif candidate['format']=='groups_knockout'
        GroupStandings.calculate(candidate:candidate,units:units,results:normalized,unit_key:team ? 'unit_ids' : 'players',players_per_match:2)['standings']
      else
        StandingsRanking.calculate(units:units,results:normalized,points:Standings::MATCH_POINTS,criteria:StandingsRanking::CRITERIA)
      end
      current,current_id=source!
      raise Blocked,:source_changed unless current==candidate && current_id==id
      value={'results'=>results,'standings'=>standings,'schedule_id'=>candidate['schedule_id']}
      completed=candidate['format']=='knockout' ? !!knockout['champion'] : candidate['format']=='round_robin' && !candidate['matches'].empty? && results.size==candidate['matches'].size
      value['completed']=completed
      value['completed_at']=result_times.max if completed && !result_times.empty?
      value['forfeitable_matches']=forfeitable if include_match_status
      value['cancellable_matches']=cancellable if include_match_status
      value.merge!(knockout.slice('knockout_state','champion','series_progress')) if knockout
      Data.freeze_tree(value)
    end

    def take_error; @errors.pop(true); rescue ThreadError; nil; end
    def operations; account!; @journal.list; end
    def reconcile(id)
      account!
      record=@journal.fetch(id)
      raise Blocked,:missing_operation unless record
      candidate,tournament_id=source!
      document=StrictJson.parse(record['values']['document_json'],max_nesting:12)
      match=candidate['matches'].find{|m|m['match_id']==document['match_id'] && m['leg']==document['leg']}
      is_forfeit=%w[ordinary-match-forfeit-v1 ordinary-match-cancel-forfeit-v1].include?(document['kind'])
      author=is_forfeit ? candidate.fetch('publication_ref').fetch('author').downcase : match && prepared_match(candidate,match)['players'].first['account']
      raise Blocked,:source_changed unless match && candidate['schedule_id']==document.fetch('schedule_id',candidate['schedule_id']) && author==@owner
      if document['kind']=='ordinary-match-create-v1'
        bound=read_document(anchor(candidate,tournament_id,match,'binding'),@owner)
        raise Blocked,:creation_unconfirmed unless bound && valid_binding?(bound,candidate,match)
        return record if record['status']=='confirmed'
        return @journal.resolve(id,status:'confirmed',evidence:{'table_id'=>bound['table']['__id'],'native_session_id'=>bound['table']['__live_session_id']},expected_revision:record['revision'])
      end
      kind=is_forfeit ? 'forfeit' : document['kind']=='ordinary-match-binding-v1' ? 'binding' : 'result'
      expected=anchor(candidate,tournament_id,match,kind)
      if document['kind']=='ordinary-match-continuation-v1'
        expected=anchor(candidate,tournament_id,match,'binding').merge('operation_key'=>Digest::SHA256.hexdigest(JSON.generate([
          'ordinary-continuation-v1',@journal.backend_identity,document['previous_digest']])))
        raise Blocked,:invalid_continuation unless valid_binding?(document['binding'],candidate,match) && document['binding'].key?('continuation')
      end
      ServerPlanArchive.new(table:@table,journal:@journal,user:-> {account!; @user.call},verify:->(doc,retained) do
        current,current_id=source!
        if kind=='forfeit'
          validate_forfeit!(doc,candidate,match)
          creator=prepared_match(candidate,match)['players'].first['account']
          if doc['kind']=='ordinary-match-cancel-forfeit-v1'
            binding=read_match_binding(candidate,tournament_id,match,creator)
            raise Blocked,:wrong_match_binding unless cancellation_valid_binding?(doc,binding,candidate,match)
          else
            raise Blocked,:conflicting_match_results if read_document(anchor(candidate,tournament_id,match,'result'),creator)
          end
        end
        retained==expected && current==candidate && current_id==tournament_id && doc==document
      end).reconcile(id).tap do
        if document['kind']=='ordinary-match-continuation-v1'
          binding=document['binding']
          if read_match_binding(candidate,tournament_id,match,@owner)==binding
            @lock.synchronize{@bindings[binding['table']['__id']]=[Data.freeze_tree(binding),candidate,tournament_id,match]}
            start_worker
          end
        end
      end
    end
    def close
      @lock.synchronize { return if @closed; @closed=true; @jobs << nil }
      @thread&.join(2) unless @thread == Thread.current
    end

    # Public for deterministic tests of the queue consumer, never a game executor.
    def collect(row)
      binding, candidate, id, match, captured = row
      current, current_id = source!
      raise Blocked, :source_changed unless current == candidate && id == current_id
      return if forfeit_document(candidate,id,match)
      return unless read_match_binding(candidate,id,match,binding['creator'])==binding
      result = captured || OrdinaryMatchResults.read(repository:@games,registry:@registry,transport:@transport,table:binding['table'],binding:binding)
      return unless result
      result=Data.freeze_tree(result.merge('publication_ref'=>candidate.fetch('publication_ref')))
      publish_document(result,anchor(candidate,id,match,'result')) do |document|
        fresh=captured || OrdinaryMatchResults.read(repository:@games,registry:@registry,transport:@transport,table:binding['table'],binding:binding)
        current,current_id=source!
        current==candidate && current_id==id && fresh && document==fresh.merge('publication_ref'=>candidate.fetch('publication_ref'))
      end
    end

    private
    def start_worker
      return if @thread
      @program.class.manage(self) if @program.class.respond_to?(:manage)
      runtime = @program.class.app_runtime if @program.class.respond_to?(:app_runtime)
      @thread = Thread.new do
        Thread.current.report_on_exception=false
        work = -> do
          while (row=@jobs.pop)
            break if @closed
            begin
              collect(row)
            rescue StandardError=>error
              @errors << error if @errors.size<16
              # A programming failure must not keep processing faulty work.
              unless error.is_a?(Blocked) || error.is_a?(Publication::Invalid) || error.is_a?(IOError) ||
                  error.is_a?(ServerPlanArchive::Unconfirmed) || error.is_a?(OperationJournal::Error) ||
                  (defined?(EltenLink::Error) && error.is_a?(EltenLink::Error))
                @lock.synchronize{@closed=true}
                break
              end
            end
          end
        end
        runtime && defined?(Programs) ? Programs.with_runtime(runtime,&work) : work.call
      ensure
        @program.class.release(self) if @program.class.respond_to?(:release)
      end
    end
    def source!
      account!
      source=@source.call
      account!
      [Data.freeze_tree(Data.copy(source.fetch('candidate').reject{|k,_|k=='observed_at'},max_bytes:262144,max_nodes:16384,max_depth:12)),source.fetch('tournament_id')]
    end
    def account!
      value=Data.account(@user.call).downcase
      @changed=true unless value==@owner
      raise Blocked,:account_changed if @changed || @closed
    end
    def anchor(candidate,id,match,kind)
      {'operation_key'=>Digest::SHA256.hexdigest(JSON.generate(['ordinary-match-v1',@journal.backend_identity,candidate['schedule_id'],match['match_id'],match['leg'],kind])),
        'tournament_id'=>id,'publication_digest'=>candidate['publication_digest'],'roster_generation'=>candidate['roster_generation']}
    end
    def read_document(anchor,author)
      account!
      rows=@table.select(where:{'operation_key'=>anchor['operation_key']},limit:ServerPlanDocument::MAX_PARTS+2).to_a
      account!
      rows.empty? ? nil : ServerPlanDocument.decode(rows,anchor:anchor,author:author)
    end
    def publish_document(document,anchor,&verify)
      previous=read_document(anchor,@owner)
      raise Blocked,:conflicting_document if previous && previous!=document
      return if previous
      ServerPlanArchive.new(table:@table,journal:@journal,user:-> {account!; @user.call},verify:->(doc,retained){account!; retained==anchor && verify.call(doc)}).
        publish(intent_id:'ordinary-document:'+anchor['operation_key'],document:document,anchor:anchor)
    end
    def valid_binding?(binding,candidate,match)
      expected=prepared_match(candidate,match)
      if binding.is_a?(Hash) && binding.key?('continuation')
        marker=binding['continuation']
        return false unless marker.is_a?(Hash) && marker.keys.sort==%w[archive_id event_count prefix_digest save_checksum] &&
          marker['archive_id'].is_a?(String) && marker['archive_id'].bytesize.between?(1,128) && Data.integer?(marker['event_count']) &&
          %w[prefix_digest save_checksum].all?{|key|marker[key].is_a?(String) && /\A[0-9a-f]{64}\z/.match?(marker[key])}
      end
      return false unless binding.is_a?(Hash) && binding['players'].is_a?(Array) && binding['players'].size==match['players'].size &&
        binding['players'].each_with_index.all?{|person,index|person.is_a?(Hash) && person.keys.sort==expected['players'][index].keys.sort &&
          person['account'].is_a?(String) && person['username'].is_a?(String) && person['username'].downcase==person['account'] && person['seat']==index} &&
        binding['table'].is_a?(Hash) && binding['table']['owner'].is_a?(String) && Data.integer?(binding['table']['__id'],1) &&
        binding['table']['__live_session_id'].is_a?(String) && !binding['table']['__live_session_id'].empty?
      binding['kind']=='ordinary-match-binding-v1' && binding['schedule_id']==candidate['schedule_id'] && binding['match_id']==match['match_id'] && binding['leg']==match['leg'] &&
        binding['creator']==expected['players'].first['account'] && binding['game_id']==candidate['game_id'] && binding['options']==expected['options'] &&
        Data.integer?(binding['session_id'],1) && binding['session_id']<=2_000_000_000 &&
        binding['players']==expected['players'] && binding['table']['owner'].downcase==binding['creator'] && binding['table']['game']==candidate['game_id']
    end

    def supported_match?(candidate,match)
      return false unless match.is_a?(Hash) && match['players'].is_a?(Array) && match['players'].size.between?(2,8)
      if match.key?('unit_ids')
        prepared_match(candidate,match)
        return true
      end
      return false if candidate['format']=='groups_knockout' && match['players'].size!=2
      game=@registry.build(candidate['game_id'])
      game && game.tournament_capabilities(options:candidate['game_options'])[:player_counts].include?(match['players'].size) &&
        game.team_size(candidate['game_options'],player_count:match['players'].size)==0
    rescue Publication::Invalid,KeyError
      false
    end

    def prepared_match(candidate,match)
      return OrdinaryTeamPlayers.prepare(candidate:candidate,match:match,registry:@registry) if match.key?('unit_ids')
      {'options'=>candidate['game_options'],'players'=>MatchOrder.players(candidate['matches'],match).each_with_index.map{|account,seat|{'account'=>account,'username'=>account,'seat'=>seat}}}
    end

    def valid_summary?(summary,match)
      return false unless summary.is_a?(Hash) && (summary.keys-%w[participants winners draw scores event_count score_order]).empty? &&
        summary['participants']==(match['unit_ids'] || match['players']).sort && summary['winners'].is_a?(Array) && summary['winners'].uniq==summary['winners'] &&
        (summary['winners']-summary['participants']).empty? && [true,false].include?(summary['draw']) &&
        (summary['draw'] ? summary['winners'].empty? : !summary['winners'].empty?) && Data.integer?(summary['event_count']) &&
        (!summary.key?('score_order') || %w[higher lower].include?(summary['score_order']))
      scores=summary['scores']
      scores.nil? || (scores.is_a?(Hash) && scores.keys.sort==summary['participants'] &&
        scores.values.all?{|value|value.is_a?(Integer) || value.is_a?(Float) && value.finite?})
    end
  end
end
