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
require_relative 'ordinary_match_entry'
require_relative 'server_document_rows'
require_relative 'server_capacity'

module GameRoomTournaments
  # Ordinary invitations, one elected creator per table, first native game only.
  # Any bound participant can retain its verified result after creator departure.
  class OrdinaryMatchService
    include OrdinaryMatchForfeit
    include OrdinarySavedMatch
    include OrdinaryMatchEntry
    class Blocked < StandardError
      attr_reader :code
      def initialize(code); @code = code; super(code.to_s); end
    end
    Data = Publication::Data
    attr_reader :owner
    def initialize(program:, registry:, lobby:, games:, transport:, table:, journal:, source:, user:, entry_guard:nil, changed:->(_reference){}, read_scope:->(&block){block.call})
      @program, @registry, @lobby, @games, @transport = program, registry, lobby, games, transport
      @table, @journal, @source, @user = table, journal, source, user
      @entry_guard,@result_changed=entry_guard,changed
      @read_scope=read_scope
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
      documents=match_documents(candidate,id,match)
      raise Blocked,:result_already_recorded if forfeit_document(candidate,id,match,rows:documents['forfeit']) ||
        read_result_document(candidate,id,match,rows:documents['result'])
      raise Blocked, :unsupported_match_players unless supported_match?(candidate,match)
      raise Blocked, :not_a_match_player unless match['players'].include?(@owner)
      raise Blocked,:private_game_not_supported if @registry.build(candidate['game_id']).private_table_required?(candidate['game_options'])
      initial=initial_match_binding(candidate,id,match,rows:documents['binding'],creator_rows:documents['creator'])
      binding=initial && read_match_binding(candidate,id,match,nil,initial:initial)
      if binding
        current_room=@lobby.current_table_for(@user.call)
        raise Blocked,:already_at_another_table if current_room && current_room['__live_session_id']!=binding['table']['__live_session_id']
        unless current_room
          # A complete discovery read, not a cached widget list or a failed
          # request. Tournament tables are public and cannot change visibility.
          available=@transport.discover_rooms(include_private:true).any?{|room|room['__live_session_id']==binding['table']['__live_session_id']}
          unless available
            replacement_allowed!(candidate,id,match,binding)
            binding=create_match_table(candidate,id,match,previous:binding)
          end
        end
      else
        binding=create_match_table(candidate,id,match)
      end
      raise Blocked, :wrong_match_binding unless valid_binding?(binding, candidate, match)
      @entry_guard&.call(candidate,match,binding)
      room = binding.fetch('table')
      current_room = @lobby.current_table_for(@user.call)
      if current_room && current_room['__live_session_id'] != room['__live_session_id']
        raise Blocked, :already_at_another_table
      end
      unless current_room && current_room['__live_session_id'] == room['__live_session_id']
        joined = @lobby.join_table(room, @user.call)
        raise Blocked, :table_join_failed unless joined && [:joined,:already_here].include?(joined.status)
        room = joined.table
      end
      account!
      remember_binding(binding,candidate,id,match)
      room
    end

    # Only an event handoff inside the existing runner's observation boundary.
    # Repository/server I/O happens later, on this separate finite-work consumer.
    def start_parameters(table, players: nil, options: nil)
      row=@lock.synchronize{@bindings[table['__id']]}
      return {} unless row && row[0]['table']['__live_session_id']==table['__live_session_id']
      account!
      binding,candidate,id,match=row
      documents=match_documents(candidate,id,match)
      raise Blocked,:result_already_recorded if forfeit_document(candidate,id,match,rows:documents['forfeit']) ||
        read_result_document(candidate,id,match,rows:documents['result'])
      raise Blocked,:not_a_match_player unless match['players'].include?(@owner) && table['owner'].to_s.downcase==@owner
      current,current_id=source!
      raise Blocked,:source_changed unless current==candidate && current_id==id
      @entry_guard&.call(candidate,match,binding)
      ordered = binding['players'].sort_by{|person|person['seat']}.map do |person|
        (players || []).find{|name|Data.account(name).downcase==person['account']} || person['username']
      end
      actual_options=options || StrictJson.parse(table.fetch('game_options'),max_nesting:12)
      game=@registry.build(binding['game_id'])
      normalized=game.normalize_options(actual_options)
      team=binding['players'].any?{|person|person.key?('team')}
      # Room order follows joins; the fixed tournament seats need not. Compare
      # the same people in planned order, not two differently ordered indices.
      normalized=game.options_for_team_roster(normalized,players:ordered) if team
      equal=team ? normalized.reject{|key,_|key=='team_players'}==binding['options'].reject{|key,_|key=='team_players'} : normalized==binding['options']
      raise Blocked,:wrong_game_options unless equal
      if players
        raise Blocked,:wrong_game_players unless players.map{|name|Data.account(name).downcase}.sort==binding['players'].map{|p|p['account']}.sort
      end
      raise Blocked,:match_already_has_a_game unless @transport.game_sessions(table,force:true).empty?
      raise Blocked,:wrong_match_binding unless read_match_binding(candidate,id,match,nil)==binding
      retain_start_intent(candidate,id,match,binding)
      result={requested_session_id:binding.fetch('session_id'), players:ordered}
      if team
        result[:options]=JSON.generate(@registry.build(binding['game_id']).with_team_assignment(binding['options'],players:ordered,seats:binding['options'].fetch('team_seats')))
      end
      result
    end

    # A fresh reference for a notification/coordinator; no native membership or
    # worker is created by this read. Completed fixtures cannot be re-entered.
    def entry_status(match_id:,leg:)
      candidate,id=source!
      match=candidate.fetch('matches').find{|row|row['match_id']==match_id && row['leg']==leg}
      raise Blocked,:missing_match unless match && supported_match?(candidate,match)
      documents=match_documents(candidate,id,match)
      raise Blocked,:result_already_recorded if forfeit_document(candidate,id,match,rows:documents['forfeit']) ||
        read_result_document(candidate,id,match,rows:documents['result'])
      initial=initial_match_binding(candidate,id,match,rows:documents['binding'],creator_rows:documents['creator'])
      binding=initial && read_match_binding(candidate,id,match,nil,initial:initial)
      raise Blocked,:wrong_match_binding if binding && !valid_binding?(binding,candidate,match)
      creator=binding && binding['creator']
      Data.freeze_tree({'candidate'=>candidate,'match'=>match,'creator'=>creator,'binding'=>binding})
    end

    def observe(table, session, replay, events=nil)
      return unless replay.finished? && session && table
      @lock.synchronize do
        row = @bindings[table['__id']]
        return unless row && row[0]['players'].any? { |person| person['account'] == @owner } && !@closed
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
      raise Blocked, :plan_too_large if candidate['matches'].size > ServerCapacity::MAX_MATCHES
      rows = ServerDocumentRows.read_keys(@table, result_document_keys(candidate,id), guard: method(:account!))
      grouped=rows.group_by{|row|row.fetch('operation_key')}
      bindings=result_bindings(candidate,id,grouped)
      read=->(key,creator) do
        entries=ServerDocumentRows.owned(grouped[key['operation_key']] || [],creator)
        entries.empty? ? nil : ServerPlanDocument.decode(entries,anchor:key,author:creator)
      end
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
            binding=read_match_binding(candidate,id,match,nil)
            raise Blocked,:wrong_match_binding unless cancellation_valid_binding?(forfeit,binding,candidate,match)
            # Explicit organizer cancellation is the sporting cutoff. Native
            # history remains untouched; any later ordinary receipt is excluded.
          else
            raise Blocked,:conflicting_match_results if read_result_document(candidate,id,match,rows:grouped[anchor(candidate,id,match,'result')['operation_key']] || [])
          end
          results << forfeit
          key=anchor(candidate,id,match,'forfeit')
          parts=ServerPlanDocument.canonical_rows(ServerDocumentRows.owned(grouped[key['operation_key']] || [],candidate['publication_ref']['author']),anchor:key,author:candidate['publication_ref']['author'])
          time=document_time(parts)
          result_times << time if time
          next
        end
        binding = bindings[[match['match_id'],match['leg']]]
        unless binding
          forfeitable << {'match_id'=>match['match_id'],'leg'=>match['leg']} if include_match_status
          next
        end
        raise Blocked, :wrong_match_binding unless valid_binding?(binding,candidate,match)
        result_time=nil
        receipt = read_result_document(candidate,id,match,rows:grouped[anchor(candidate,id,match,'result')['operation_key']] || []) { |time| result_time=time }
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
        result_times << result_time if result_time
      end
      result_summary(candidate, id, results, result_times, forfeitable, cancellable, include_match_status: include_match_status)
    end

    def result_document_keys(candidate,id)
      candidate.fetch('matches').flat_map{|match|%w[creator binding result forfeit].map{|kind|anchor(candidate,id,match,kind)['operation_key']}}
    end

    # Traverse independent binding chains together. The same authenticated
    # lineage validation is used by entry/recovery; only SDK reads are batched.
    private def result_bindings(candidate,id,grouped)
      completed={}
      pending=candidate['matches'].filter_map do |match|
        next unless supported_match?(candidate,match)
        forfeit_rows=grouped[anchor(candidate,id,match,'forfeit')['operation_key']] || []
        next unless ServerDocumentRows.owned(forfeit_rows,candidate['publication_ref']['author']).empty?
        binding=initial_match_binding(candidate,id,match,rows:grouped[anchor(candidate,id,match,'binding')['operation_key']] || [],
          creator_rows:grouped[anchor(candidate,id,match,'creator')['operation_key']] || [])
        [match,binding] if binding
      end
      64.times do
        return completed if pending.empty?
        pending.each { |match,binding| raise Blocked,:wrong_match_binding unless valid_binding?(binding,candidate,match) }
        keys=pending.flat_map do |match,binding|
          [entry_anchor(candidate,id,match,'creator',binding)['operation_key'],continuation_anchor(candidate,id,match,binding)['operation_key']]
        end
        documents=ServerDocumentRows.read_keys(@table,keys,guard:method(:account!)).group_by{|row|row.fetch('operation_key')}
        pending=pending.filter_map do |match,binding|
          following=next_match_binding(candidate,id,match,binding,
            creator_rows:documents[entry_anchor(candidate,id,match,'creator',binding)['operation_key']] || [],
            continuation_rows:documents[continuation_anchor(candidate,id,match,binding)['operation_key']] || [])
          if following
            [match,following]
          else
            completed[[match['match_id'],match['leg']]]=binding
            nil
          end
        end
      end
      raise Blocked,:continuation_limit unless pending.empty?
      completed
    end

    private def result_summary(candidate, id, results, result_times, forfeitable, cancellable, include_match_status:)
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
      if result_times.size==results.size && !result_times.empty?
        value['completed_at']=result_times.max if completed
        value['progress_times']=result_times.uniq.sort
      end
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
      if match && entry_operation?(document)
        return reconcile_entry_operation(record,document,candidate,tournament_id,match)
      end
      is_forfeit=%w[ordinary-match-forfeit-v1 ordinary-match-cancel-forfeit-v1].include?(document['kind'])
      author=is_forfeit ? candidate.fetch('publication_ref').fetch('author').downcase : match && prepared_match(candidate,match)['players'].first['account']
      if match && document['kind']=='ordinary-match-continuation-v1'
        previous=read_match_binding(candidate,tournament_id,match,nil,stop_at:document['previous_digest'])
        raise Blocked,:invalid_continuation unless previous && binding_digest(previous)==document['previous_digest'] &&
          document.dig('binding','creator')==previous['creator']
        author=previous['creator']
      end
      authorized = author == @owner || document['kind'] == 'ordinary-match-result-v1' && match && match['players'].include?(@owner)
      raise Blocked,:source_changed unless match && candidate['schedule_id']==document.fetch('schedule_id',candidate['schedule_id']) && authorized
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
            raise Blocked,:conflicting_match_results if read_result_document(candidate,tournament_id,match)
          end
        end
        retained==expected && current==candidate && current_id==tournament_id && doc==document
      end).resume(id).tap do
        @result_changed.call(candidate.fetch('publication_ref')) if %w[forfeit result].include?(kind)
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
      # The runner already verified this terminal history. Retain its immutable
      # result locally before the first network read, so an outage cannot lose
      # the only completion callback. This grants no permission to publish:
      # the normal archive and recovery paths still revalidate the source.
      result=captured && retain_result(captured,candidate,id,match)
      current, current_id = source!
      raise Blocked, :source_changed unless current == candidate && id == current_id
      documents=match_documents(candidate,id,match)
      return if forfeit_document(candidate,id,match,rows:documents['forfeit'])
      return unless read_match_binding(candidate,id,match,binding['creator'])==binding
      result ||= OrdinaryMatchResults.read(repository:@games,registry:@registry,transport:@transport,table:binding['table'],binding:binding)
      return unless result
      result=retain_result(result,candidate,id,match) unless captured
      publish_document(result,anchor(candidate,id,match,'result')) do |document|
        fresh=captured || OrdinaryMatchResults.read(repository:@games,registry:@registry,transport:@transport,table:binding['table'],binding:binding)
        current,current_id=source!
        current==candidate && current_id==id && fresh && document==fresh.merge('publication_ref'=>candidate.fetch('publication_ref'))
      end
      @result_changed.call(candidate.fetch('publication_ref'))
    end

    private
    def retain_result(result,candidate,id,match)
      account!
      document=Data.freeze_tree(ServerPlanDocument.copy_document(result.merge('publication_ref'=>candidate.fetch('publication_ref'))))
      key=anchor(candidate,id,match,'result')
      @journal.prepare(kind:'plan_document',intent_id:'ordinary-document:'+key['operation_key'],
        values:key.merge('kind'=>'plan_document','document_json'=>JSON.generate(document)))
      document
    end

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
    def read_document(anchor,author,rows:nil)
      account!
      rows ||= ServerDocumentRows.read(@table,where:{'operation_key'=>anchor['operation_key']},author:author,guard:method(:account!))
      rows=ServerDocumentRows.owned(rows,author)
      account!
      rows.empty? ? nil : ServerPlanDocument.decode(rows,anchor:anchor,author:author)
    end

    def match_documents(candidate,id,match)
      keys=%w[creator binding result forfeit].to_h{|kind|[kind,anchor(candidate,id,match,kind)['operation_key']]}
      rows=ServerDocumentRows.read(@table,where:{'operation_key'=>{'in'=>keys.values}},
        guard:method(:account!)).group_by{|row|row['operation_key']}
      keys.transform_values{|key|rows.fetch(key,[])}
    end

    def read_result_document(candidate, id, match, rows: nil)
      key = anchor(candidate,id,match,'result')
      rows ||= ServerDocumentRows.read(@table,where:{'operation_key'=>key['operation_key']},guard:method(:account!))
      receipts = []
      incomplete = false
      rows.group_by { |row| row['__insertion_user'].to_s.downcase }.each do |author, parts|
        next unless match['players'].include?(author)
        begin
          receipt = ServerPlanDocument.decode(parts,anchor:key,author:author)
          raise Blocked,:invalid_result_receipt unless receipt['kind']=='ordinary-match-result-v1' &&
            receipt['publication_ref']==candidate['publication_ref'] && receipt['match_id']==match['match_id'] && receipt['leg']==match['leg'] &&
            Data.integer?(receipt['session_id'],1) && %w[binding_digest history_digest].all? { |field| receipt[field].is_a?(String) && /\A[0-9a-f]{64}\z/.match?(receipt[field]) } &&
            valid_summary?(receipt['summary'],match)
          canonical=ServerPlanDocument.canonical_rows(parts,anchor:key,author:author)
          receipts << [canonical.map { |row|row['__id'] }.max, receipt, document_time(canonical)]
        rescue Publication::Invalid => error
          raise unless error.code == :incomplete_plan_document
          incomplete = true
        end
      end
      raise ServerPlanArchive::Unconfirmed,'Result is incomplete' if receipts.empty? && incomplete
      return nil if receipts.empty?
      receipts.sort_by!(&:first)
      chosen = receipts.first[1]
      sporting = ->(value) { value.slice('binding_digest','session_id','match_id','leg').merge(
        'summary'=>value['summary'].reject { |field,_|field=='event_count' }) }
      raise Blocked,:conflicting_match_results unless receipts.all? { |_,value| sporting.call(value)==sporting.call(chosen) }
      yield receipts.first[2] if block_given?
      chosen
    end

    def document_time(parts)
      times=parts.map { |row| row['__insertion_time'] }
      times.max if times.all? { |time| Data.integer?(time) }
    end
    def publish_document(document,anchor,&verify)
      begin
        previous=read_document(anchor,@owner)
      rescue Publication::Invalid => error
        raise unless error.code == :incomplete_plan_document
      end
      raise Blocked,:conflicting_document if previous && previous!=document
      return if previous
      ServerPlanArchive.new(table:@table,journal:@journal,user:-> {account!; @user.call},verify:->(doc,retained){account!; retained==anchor && verify.call(doc)}).
        publish(intent_id:'ordinary-document:'+anchor['operation_key'],document:document,anchor:anchor)
    end
    def valid_binding?(binding,candidate,match)
      expected=prepared_match(candidate,match)
      if binding.is_a?(Hash) && binding.key?('continuation')
        marker=binding['continuation']
        return false unless marker.is_a?(Hash) && marker.keys.sort==(%w[archive_id event_count prefix_digest save_checksum]+(marker.key?('start_reserved') ? ['start_reserved'] : [])) &&
          (!marker.key?('start_reserved') || marker['start_reserved']==true) &&
          marker['archive_id'].is_a?(String) && marker['archive_id'].bytesize.between?(1,128) && Data.integer?(marker['event_count']) &&
          %w[prefix_digest save_checksum].all?{|key|marker[key].is_a?(String) && /\A[0-9a-f]{64}\z/.match?(marker[key])}
      end
      return false unless binding.is_a?(Hash) && binding['players'].is_a?(Array) && binding['players'].size==match['players'].size &&
        binding['players'].each_with_index.all?{|person,index|person.is_a?(Hash) && person.keys.sort==expected['players'][index].keys.sort &&
          person['account'].is_a?(String) && person['username'].is_a?(String) && person['username'].downcase==person['account'] && person['seat']==index} &&
        binding['table'].is_a?(Hash) && binding['table']['owner'].is_a?(String) && Data.integer?(binding['table']['__id'],1) &&
        binding['table']['__live_session_id'].is_a?(String) && !binding['table']['__live_session_id'].empty?
      return false if binding.key?('entry_version') && binding['entry_version']!=ENTRY_VERSION
      if binding['entry_version']==ENTRY_VERSION
        marker=candidate.slice('publication_ref','schedule_id').merge(match.slice('match_id','leg'))
        return false unless binding['table']['tournament_match']==marker ||
          binding.key?('continuation') && !binding['table'].key?('tournament_match')
      end
      binding['publication_ref']==candidate['publication_ref'] && binding['kind']=='ordinary-match-binding-v1' && binding['schedule_id']==candidate['schedule_id'] && binding['match_id']==match['match_id'] && binding['leg']==match['leg'] &&
        (binding['entry_version']==ENTRY_VERSION ? match['players'].include?(binding['creator']) : binding['creator']==expected['players'].first['account']) && binding['game_id']==candidate['game_id'] && binding['options']==expected['options'] &&
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

    module WorkerReads
      %i[open_match attach_table start_parameters entry_status result_view collect reconcile
        saved_match_reference check_saved_match prepare_saved_match start_saved_match bind_resumed_match award_forfeit].each do |name|
        define_method(name) do |*args,**keywords,&block|
          @read_scope.call { super(*args,**keywords,&block) }
        end
      end
    end
    prepend WorkerReads
  end
end
