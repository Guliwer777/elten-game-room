# encoding: UTF-8
require_relative 'server_plan_archive'
require_relative '../game_room_clock'

module GameRoomTournaments
  # Authenticated append-only availability observations. Never a reservation,
  # sealed proposal, execution grant or a ProposalNotice backend.
  class ServerReadinessService
    TTL = 60
    # ServerClock samples have second-resolution and a documented uncertainty
    # of RTT / 2 + 1 s (RTT is below 5 s). Integer conversion adds up to 1 s.
    # This only validates incoming server stamps; it never extends deadlines.
    STAMP_SKEW = 5
    KIND = 'tournament-shared-readiness-v1'.freeze
    Data = Publication::Data

    class EventTable
      def initialize(table, digest); @table, @digest = table, digest; end
      def insert(row); @table.insert(row); end
      def select(where:, limit:, order: nil)
        @table.select(where: where.merge('document_digest'=>@digest), limit: limit, order: order).to_a
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
      @journal.trim_confirmed_presence
      archive(document, source).publish(intent_id:'shared-ready:'+intent_id, document:document, anchor:retained)
      snapshot
    end

    def reconcile(id)
      record = @journal.fetch(id)
      raise OperationJournal::Invalid,:missing_plan_operation unless record && record['kind']=='plan_document'
      document = StrictJson.parse(record['values']['document_json'],max_nesting:12)
      archive(document,source!).resume(id)
    end

    def snapshot(since: {})
      source = source!
      candidate = source['candidate']
      people = candidate['roster']
      anchors = people.to_h{|person|[person,anchor(source,person)]}
      # Read the bounded append-only history, not just recent timestamps. A
      # repeated old header must not renew availability; its first ID/time is
      # authoritative. Nor may a short server page hide a later withdrawal.
      rows = anchors.values.each_slice(96).flat_map do |batch|
        ServerDocumentRows.read(@table,where:{'operation_key'=>{'in'=>batch.map{|value|value['operation_key']}}},guard:method(:account!))
      end
      now = clock!
      grouped = rows.group_by{|row|row['operation_key']}
      states = people.map do |person|
        state_for(grouped[anchors[person]['operation_key']] || [],anchors[person],person,source,now,since[person])
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

    def state_for(rows,retained,account,source,now,since=nil)
      result={'account'=>account,'state'=>'not_ready','expires_at'=>nil,'revision'=>nil}
      result['continuous']=false if since
      rows = ServerDocumentRows.owned(rows, account)
      return result if rows.empty?
      rows.each{|row|Data.metadata(row)}
      raise Publication::Invalid,:duplicate_readiness_row unless rows.map{|row|row['__id']}.uniq.size==rows.size
      headers=rows.select{|row|row['part_index']==0}
      raise Publication::Invalid,:incomplete_readiness unless rows.all?{|row|headers.any?{|header|header['document_digest']==row['document_digest']}}
      headers=headers.group_by{|row|row['document_digest']}.values.map{|group|group.min_by{|row|row['__id']}}.sort_by{|row|row['__id']}
      latest=headers.last
      raise Publication::Invalid,:incomplete_readiness unless latest
      parts=rows.select{|row|row['document_digest']==latest['document_digest']}
      document=ServerPlanDocument.decode(parts,anchor:retained,author:account)
      validate_document!(document,source,account)
      raise Publication::Invalid,:invalid_readiness_time if latest['__insertion_time']>now+STAMP_SKEW
      expires=latest['__insertion_time']+TTL
      result['continuous']=continuous_since?(headers,rows,retained,account,source,now,since) if since
      result.merge('state'=>document['available'] && now<expires ? 'ready' : 'not_ready','expires_at'=>document['available'] ? expires : nil,'revision'=>latest['document_digest'])
    rescue Publication::Invalid,JSON::ParserError
      result.merge('state'=>'unknown')
    end

    # A heartbeat is not a new decision. Only complete, uninterrupted renewals
    # after the proposal's observation preserve its consent. A withdrawal,
    # missing part or expired lease cannot be hidden by a later Ready record.
    def continuous_since?(headers,rows,retained,account,source,now,revision)
      ServerPlanDocument.digest!(revision)
      index=headers.index{|header|header['document_digest']==revision}
      return false unless index
      previous_expiry=nil
      parts=rows.group_by{|row|row['document_digest']}
      headers.drop(index).each do |header|
        stamp=header['__insertion_time']
        return false if stamp>now+STAMP_SKEW || previous_expiry && stamp>=previous_expiry
        document=ServerPlanDocument.decode(parts.fetch(header['document_digest']),anchor:retained,author:account)
        validate_document!(document,source,account)
        return false unless document['available']
        previous_expiry=stamp+TTL
      end
      true
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
