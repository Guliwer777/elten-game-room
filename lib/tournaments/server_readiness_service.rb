# encoding: UTF-8
require_relative 'server_plan_archive'
require_relative '../game_room_clock'

module GameRoomTournaments
  # Authenticated append-only availability observations. Never a reservation,
  # sealed proposal, execution grant or a ProposalNotice backend.
  class ServerReadinessService
    TTL = 60
    READ_LIMIT = 1000
    KIND = 'tournament-shared-readiness-v1'.freeze
    Data = Publication::Data

    class EventTable
      def initialize(table, digest); @table, @digest = table, digest; end
      def insert(row); @table.insert(row); end
      def select(where:, limit:)
        @table.select(where: where.merge('document_digest'=>@digest), limit: limit).to_a
      end
    end

    def initialize(table:, journal:, user:, source:, clock:, guard: -> {true})
      @table, @journal, @user, @source, @clock, @guard = table, journal, user, source, clock, guard
      @owner, @changed = journal.owner, false
      account!
    end

    def set_available(available:, intent_id:)
      raise ArgumentError, 'Availability must be boolean' unless [true,false].include?(available)
      Data.key!(intent_id)
      clock!
      source = source!
      raise Publication::Invalid,:not_registered unless source['candidate']['roster'].include?(@owner)
      document = Data.freeze_tree(ServerPlanDocument.copy_document({'kind'=>KIND, 'publication_ref'=>source['candidate']['publication_ref'],
        'schedule_id'=>source['candidate']['schedule_id'], 'account'=>@owner, 'available'=>available, 'nonce'=>intent_id}))
      retained = anchor(source, @owner)
      archive(document, source).publish(intent_id:'shared-ready:'+intent_id, document:document, anchor:retained)
      snapshot
    end

    def reconcile(id)
      record = @journal.fetch(id)
      raise OperationJournal::Invalid,:missing_plan_operation unless record && record['kind']=='plan_document'
      document = StrictJson.parse(record['values']['document_json'],max_nesting:12)
      archive(document,source!).reconcile(id)
    end

    def snapshot
      source = source!
      candidate = source['candidate']
      people = candidate['roster']
      anchors = people.to_h{|person|[person,anchor(source,person)]}
      cutoff=[clock!-TTL,0].max
      # Expired history cannot authorize readiness. A late orphan payload still
      # becomes unknown, rather than reviving its already expired header.
      rows = @table.select(where:{'operation_key'=>{'in'=>anchors.values.map{|value|value['operation_key']}},'__insertion_time'=>{'gte'=>cutoff}},
        order:[['__id','desc']],limit:READ_LIMIT).to_a
      account!
      raise Publication::Invalid,:readiness_read_limit if rows.size >= READ_LIMIT
      rows = Data.copy(rows,max_bytes:4_194_304,max_nodes:32_768,max_depth:8)
      headers=rows.select{|row|row['part_index']==0}
      unless headers.empty?
        # ID order is authoritative even if the server clock moved backwards.
        # A newer expired withdrawal must not disappear behind a time filter.
        headers.each{|row|Data.metadata(row)}
        newer=@table.select(where:{'operation_key'=>{'in'=>anchors.values.map{|value|value['operation_key']}},
          'part_index'=>0,'__id'=>{'gte'=>headers.map{|row|row['__id']}.min}},order:[['__id','desc']],limit:READ_LIMIT).to_a
        account!
        raise Publication::Invalid,:readiness_read_limit if newer.size>=READ_LIMIT
        newer=Data.copy(newer,max_bytes:2_097_152,max_nodes:32_768,max_depth:8)
        newer.each do |row|
          existing=rows.find{|old|old['__id']==row['__id']}
          raise Publication::Invalid,:changed_readiness_row if existing && existing!=row
          rows << row unless existing
        end
      end
      now = clock!
      grouped = rows.group_by{|row|row['operation_key']}
      states = people.map do |person|
        state_for(grouped[anchors[person]['operation_key']] || [],anchors[person],person,source,now)
      end
      raise ServerPlanArchive::ContextChanged,'Tournament source changed' unless source! == source
      Data.freeze_tree({'state'=>'observed','schedule_id'=>candidate['schedule_id'],'participants'=>states,'ttl'=>TTL})
    end

    private

    def clock!
      now=@clock.call
      raise Publication::Invalid,:invalid_clock unless Data.integer?(now)
      now
    end

    def archive(document,source)
      validate_document!(document,source,@owner)
      digest = Digest::SHA256.hexdigest(JSON.generate(ServerPlanDocument.copy_document(document)))
      ServerPlanArchive.new(table:EventTable.new(@table,digest),journal:@journal,user:-> {account!},verify:->(value,retained){
        account!
        validate_document!(value,source,@owner)
        source! == source && retained == anchor(source,@owner)
      })
    end

    def source!
      account!
      raise ServerPlanArchive::ContextChanged,'View changed' unless @guard.call
      value = Data.copy(@source.call,max_bytes:262_144,max_nodes:16_384,max_depth:12)
      candidate = value.fetch('candidate').reject{|key,_|key=='observed_at'}
      reference=candidate['publication_ref']
      raise Publication::Invalid,:invalid_readiness_source unless reference.is_a?(Hash) && reference.keys.sort==%w[author publication_key]
      Data.account(reference['author'])
      Data.key!(reference['publication_key'])
      unless Data.integer?(value['tournament_id'],1) && candidate['state']=='observed_candidate' && candidate['finality']=='unknown' &&
          %w[start_allowed dispatch_allowed finalize_allowed].all?{|key|candidate[key]==false} &&
          candidate['roster'].is_a?(Array) && candidate['roster'].size.between?(2,256) &&
          candidate['roster'].uniq==candidate['roster'] &&
          candidate['roster'].all?{|account|Data.account(account).downcase==account}
        raise Publication::Invalid,:invalid_readiness_source
      end
      %w[schedule_id publication_digest roster_generation].each{|key|ServerPlanDocument.digest!(candidate[key])}
      account!
      Data.freeze_tree({'candidate'=>candidate,'tournament_id'=>value['tournament_id']})
    end

    def anchor(source,account)
      candidate=source['candidate']
      {'tournament_id'=>source['tournament_id'], 'publication_digest'=>candidate['publication_digest'], 'roster_generation'=>candidate['roster_generation'],
        'operation_key'=>Digest::SHA256.hexdigest(JSON.generate(['shared-readiness-v1',@journal.backend_identity,source['tournament_id'],candidate['schedule_id'],account]))}
    end

    def validate_document!(document,source,account)
      unless document.is_a?(Hash) && document.keys.sort==%w[account available kind nonce publication_ref schedule_id] &&
          document['kind']==KIND && document['account']==account && [true,false].include?(document['available']) &&
          document['schedule_id']==source['candidate']['schedule_id'] && document['publication_ref']==source['candidate']['publication_ref']
        raise Publication::Invalid,:invalid_readiness_document
      end
      Data.key!(document['nonce'])
    end

    def state_for(rows,retained,account,source,now)
      result={'account'=>account,'state'=>'not_ready','expires_at'=>nil,'revision'=>nil}
      return result if rows.empty?
      rows.each{|row|Data.metadata(row)}
      raise Publication::Invalid,:duplicate_readiness_row unless rows.map{|row|row['__id']}.uniq.size==rows.size
      headers=rows.select{|row|row['part_index']==0}
      raise Publication::Invalid,:incomplete_readiness unless rows.all?{|row|headers.any?{|header|header['document_digest']==row['document_digest']}}
      latest=headers.max_by{|row|row['__id']}
      raise Publication::Invalid,:incomplete_readiness unless latest
      parts=rows.select{|row|row['document_digest']==latest['document_digest']}
      document=ServerPlanDocument.decode(parts,anchor:retained,author:account)
      validate_document!(document,source,account)
      raise Publication::Invalid,:invalid_readiness_time if latest['__insertion_time']>now
      expires=latest['__insertion_time']+TTL
      result.merge('state'=>document['available'] && now<expires ? 'ready' : 'not_ready','expires_at'=>document['available'] ? expires : nil,'revision'=>latest['document_digest'])
    rescue Publication::Invalid,JSON::ParserError
      result.merge('state'=>'unknown')
    end

    def account!
      value=Data.account(@user.call)
      @changed=true unless value.downcase==@owner
      raise ServerPlanArchive::ContextChanged,'Account changed' if @changed
      value
    rescue Publication::Invalid
      @changed=true
      raise ServerPlanArchive::ContextChanged,'Account unavailable'
    end
  end
end
