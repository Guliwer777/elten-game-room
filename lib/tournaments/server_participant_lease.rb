require_relative 'server_readiness_service'

module GameRoomTournaments
  # One observed lease per authenticated account across tournaments. Appends
  # are ordered by server IDs; competing claims are resolved by the first
  # complete claim. This is not a server CAS or a native-session transaction.
  class ServerParticipantLease
    TTL=120
    KIND='tournament-participant-lease-v1'.freeze
    Data=Publication::Data
    class Busy < StandardError; end

    def initialize(table:,journal:,user:,clock:)
      @table,@journal,@user,@clock=table,journal,user,clock
      @owner=journal.owner
      @changed=false
    end

    def acquire(subject:,token:)
      subject=subject!(subject)
      ServerPlanDocument.digest!(token)
      active=state
      raise Busy,'Another tournament match already reserves this account' if active && active['token']!=token
      return active if active && active['subject']==subject
      write('acquire',subject,token)
      confirmed=state
      raise Busy,'A competing match reserved this account' unless confirmed && confirmed['token']==token && confirmed['subject']==subject
      confirmed
    end

    def renew(token:)
      current=state
      return nil unless current && current['token']==token
      write('renew',current['subject'],token)
      state
    end

    def release(token:)
      current=state
      return unless current && current['token']==token
      write('release',current['subject'],token)
      state
    end

    def reconcile(id)
      check!
      record=@journal.fetch(id)
      raise OperationJournal::Invalid,:missing_plan_operation unless record && record['kind']=='plan_document'
      document=StrictJson.parse(record['values']['document_json'],max_nesting:12)
      validate!(document,@owner)
      raise Publication::Invalid,:plan_not_authorized unless [anchor(@owner),event_anchor(document,@owner)].include?(record['values'].slice(*ServerPlanArchive::ANCHOR_FIELDS))
      if now!>=document['expires_at']
        return record if %w[confirmed outside_window].include?(record['status'])
        # Expiry is evidence that this ephemeral intent can no longer reserve
        # anyone. Do not finish its upload or discard a durable game operation.
        return @journal.resolve(id,status:'outside_window',evidence:{'expires_at'=>document['expires_at']},expected_revision:record['revision'])
      end
      archive(document).resume(id)
    end

    def state(account:@owner)
      history(account).fetch('current')
    end

    private

    def history(account)
      check!
      account=Data.account(account).downcase
      retained=anchor(account)
      seed=checkpoint(retained,account)
      now=now!
      rows=ServerDocumentRows.read(@table,where:{'operation_key'=>retained['operation_key']},author:account,guard:method(:check!),after_id:seed['through'])
      events=rows.group_by{|row|row['document_digest']}.filter_map do |digest,parts|
        next if seed['seen'].key?(digest)
        # A tail may contain the last part of an old, abandoned upload. Read
        # its original header, never give it the timestamp of the late part.
        unless parts.any?{|row|row['part_index']==0}
          parts=document_rows(retained,account,digest)
        end
        canonical=canonical_parts(parts,account)
        first=canonical.find{|row|row['part_index']==0}
        raise Publication::Invalid,:incomplete_plan_document unless first
        stamp=first['__insertion_time']
        valid_stamp!(stamp,now)
        complete=canonical.size==first['part_count']+1
        next if !complete && now>=stamp+TTL
        # Finishing an upload after its maximum lifetime cannot revive it.
        next if canonical.any?{|row|Data.integer?(row['__insertion_time']) && row['__insertion_time']>=stamp+TTL}
        document=decode_event(canonical,account)
        # Withdrawal is permanent, even if this release reached the server
        # after another client renewed the same token and wrote a checkpoint.
        next if document['action']!='release' && document['expires_at']<=seed['observed_at']
        [first['__id'],stamp,document.reject{|key,_|key=='checkpoint'},digest]
      end.sort_by(&:first)
      current=seed['current']
      released=seed['released'].dup
      seen=seed['seen'].dup
      events.each do |id,stamp,event,digest|
        raise Publication::Invalid,:invalid_lease_time unless event['expires_at']<=stamp+TTL+ServerReadinessService::STAMP_SKEW
        # A delayed append cannot prolong a claim. Even if the writer's clock
        # was ahead, the canonical server stamp caps its lifetime.
        event=event.merge('expires_at'=>[event['expires_at'],stamp+TTL].min)
        seen[digest]=event['expires_at']
        current=nil if current && stamp>=current['expires_at']
        token=event['token']
        case event['action']
        when 'release'
          released[token]=stamp+TTL
          current=nil if current && current['token']==token
        when 'acquire'
          unless current || released[token] || event['expires_at']<=stamp
            # Release tombstones outlive a heartbeat/checkpoint window. New
            # rows index action/token in the existing unused anchor columns.
            # Old zero-anchor releases are checked only for a new claim, not
            # on every renewal. No schema change or server deletion is needed.
            current=event unless seed['through']>0 && released_before?(account,token,id)
          end
        when 'renew'
          current=event if current && current['token']==token && current['subject']==event['subject'] && event['expires_at']>stamp
        end
      end
      current=nil if current && now>=current['expires_at']
      Data.freeze_tree({'through'=>rows.map{|row|row['__id']}.max || seed['through'], 'observed_at'=>now,
        'current'=>current,'released'=>released.select{|_,expiry|expiry>now},'seen'=>seen.select{|_,expiry|expiry>now}})
    end

    # Each new event carries the fully observed prefix, authenticated by the
    # same account as the lease. Concurrent appends after `through` are always
    # replayed, even if their IDs precede this checkpoint's own header. This
    # is a bounded read checkpoint, not a CAS or an anti-cheat claim. Old data
    # is read once when upgrading; server records are never deleted here.
    def checkpoint(retained,account)
      check!
      headers=ServerDocumentRows.page(@table,{'operation_key'=>retained['operation_key'],'part_index'=>0},[['__id','desc']],8)
      check!
      digests=ServerDocumentRows.owned(headers,account).map{|row|row['document_digest']}.uniq
      return empty_checkpoint if digests.empty?
      digests.each{|digest|ServerPlanDocument.digest!(digest)}
      grouped=ServerDocumentRows.read(@table,where:{'operation_key'=>retained['operation_key'],'document_digest'=>{'in'=>digests}},author:account,guard:method(:check!)).group_by{|row|row['document_digest']}
      candidates=grouped.values.filter_map do |parts|
        canonical=canonical_parts(parts,account)
        first=canonical.find{|row|row['part_index']==0}
        next unless first && canonical.size==first['part_count']+1
        document=decode_event(canonical,account)
        value=document['checkpoint']
        next unless value
        raise Publication::Invalid,:invalid_lease_checkpoint unless value['through']<first['__id'] &&
          Data.integer?(first['__insertion_time']) && value['observed_at']<=first['__insertion_time']+ServerReadinessService::STAMP_SKEW
        value
      end
      candidates.max_by{|value|value['through']} || empty_checkpoint
    end

    def empty_checkpoint
      {'through'=>0,'observed_at'=>0,'current'=>nil,'released'=>{},'seen'=>{}}
    end

    def document_rows(retained,account,digest)
      ServerPlanDocument.digest!(digest)
      ServerDocumentRows.read(@table,where:{'operation_key'=>retained['operation_key'],'document_digest'=>digest},author:account,guard:method(:check!))
    end

    def valid_stamp!(stamp,now)
      raise Publication::Invalid,:invalid_lease_time unless Data.integer?(stamp) && stamp<=now+ServerReadinessService::STAMP_SKEW
    end

    def canonical_parts(parts,account)
      retained=parts.first.slice(*ServerPlanArchive::ANCHOR_FIELDS)
      base=anchor(account)
      raise Publication::Invalid,:plan_author_or_scope unless retained.slice('operation_key','tournament_id')==base.slice('operation_key','tournament_id')
      ServerPlanDocument.canonical_rows(parts,anchor:retained,author:account)
    end

    def decode_event(parts,account)
      retained=parts.first.slice(*ServerPlanArchive::ANCHOR_FIELDS)
      document=ServerPlanDocument.decode(parts,anchor:retained,author:account)
      validate!(document,account)
      raise Publication::Invalid,:plan_author_or_scope unless [anchor(account),event_anchor(document,account)].include?(retained)
      document
    end

    def released_before?(account,token,before_id)
      base=anchor(account)
      selectors=[base,base.merge('publication_digest'=>action_digest('release'),'roster_generation'=>token)]
      selectors.any? do |selector|
        rows=ServerDocumentRows.read(@table,where:selector,author:account,guard:method(:check!))
        rows.group_by{|row|row['document_digest']}.values.any? do |parts|
          canonical=canonical_parts(parts,account)
          first=canonical.find{|row|row['part_index']==0}
          next false unless first && first['__id']<before_id && canonical.size==first['part_count']+1
          next false if canonical.any?{|row|row['__insertion_time']>=first['__insertion_time']+TTL}
          event=decode_event(canonical,account)
          event['action']=='release' && event['token']==token
        end
      end
    end

    def action_digest(action)
      Digest::SHA256.hexdigest('participant-lease-action:'+action)
    end

    def event_anchor(document,account)
      anchor(account).merge('publication_digest'=>action_digest(document['action']),'roster_generation'=>document['token'])
    end

    def write(action,subject,token)
      previous=history(@owner)
      if action=='acquire' && (previous['released'].key?(token) || released_before?(@owner,token,OperationJournal::MAX_INTEGER))
        raise Busy,'This reservation was already released'
      end
      now=now!
      @journal.list.each do |record|
        next unless record['kind']=='plan_document' && %w[prepared attempted].include?(record['status'])
        value=StrictJson.parse(record['values']['document_json'],max_nesting:12)
        reconcile(record['id']) if value['kind']==KIND && Data.integer?(value['expires_at']) && now>=value['expires_at']
      end
      @journal.trim_confirmed_presence
      document={'kind'=>KIND,'account'=>@owner,'action'=>action,'subject'=>subject,'token'=>token,
        'expires_at'=>now+TTL,'nonce'=>SecureRandom.uuid,'checkpoint'=>previous}
      archive(document).publish(intent_id:'participant-lease:'+document['nonce'],document:document,anchor:event_anchor(document,@owner))
    end

    def archive(document)
      digest=Digest::SHA256.hexdigest(JSON.generate(ServerPlanDocument.copy_document(document)))
      # Lease documents attest only this account and expiry, not tournament
      # eligibility. Refresh their own log here; proposal/entry authorization
      # independently refreshes publication and registration before acting.
      ServerPlanArchive.new(table:ServerReadinessService::EventTable.new(@table,digest),journal:@journal,user:@user,
        refresh:-> {ServerReadScope.refresh!(only:@table)},
        verify:->(value,retained){check!;validate!(value,@owner);[anchor(@owner),event_anchor(value,@owner)].include?(retained) && value==document && now!<value['expires_at']})
    end

    def anchor(account)
      {'operation_key'=>Digest::SHA256.hexdigest(JSON.generate([KIND,@journal.backend_identity,account])),
        'tournament_id'=>1,'publication_digest'=>'0'*64,'roster_generation'=>'0'*64}
    end

    def subject!(value)
      value=Data.copy(value,max_bytes:2048,max_nodes:64,max_depth:4)
      unless value.is_a?(Hash) && value.keys.sort==%w[leg match_id publication_ref schedule_id] && [1,2].include?(value['leg']) &&
          value['publication_ref'].is_a?(Hash) && value['publication_ref'].keys.sort==%w[author publication_key]
        raise Publication::Invalid,:invalid_lease_subject
      end
      %w[match_id schedule_id].each{|key|ServerPlanDocument.digest!(value[key])}
      Data.account(value['publication_ref']['author'])
      Data.key!(value['publication_ref']['publication_key'])
      Data.freeze_tree(value)
    end

    def validate!(value,account)
      fields=%w[account action expires_at kind nonce subject token]
      unless value.is_a?(Hash) && [fields,(fields+['checkpoint']).sort].include?(value.keys.sort) &&
          value['kind']==KIND && value['account']==account && %w[acquire renew release].include?(value['action']) && Data.integer?(value['expires_at'])
        raise Publication::Invalid,:invalid_participant_lease
      end
      subject!(value['subject'])
      ServerPlanDocument.digest!(value['token'])
      Data.key!(value['nonce'])
      if value.key?('checkpoint')
        snapshot=value['checkpoint']
        unless snapshot.is_a?(Hash) && snapshot.keys.sort==%w[current observed_at released seen through] &&
            Data.integer?(snapshot['through']) && Data.integer?(snapshot['observed_at']) &&
            snapshot['observed_at']<value['expires_at'] && snapshot['released'].is_a?(Hash) && snapshot['seen'].is_a?(Hash)
          raise Publication::Invalid,:invalid_lease_checkpoint
        end
        snapshot.values_at('released','seen').each do |entries|
          raise Publication::Invalid,:invalid_lease_checkpoint if entries.size>1024
          entries.each do |key,expiry|
            ServerPlanDocument.digest!(key)
            raise Publication::Invalid,:invalid_lease_checkpoint unless Data.integer?(expiry) &&
              expiry>snapshot['observed_at'] && expiry<=snapshot['observed_at']+TTL+ServerReadinessService::STAMP_SKEW
          end
        end
        if (current=snapshot['current'])
          raise Publication::Invalid,:invalid_lease_checkpoint unless current.is_a?(Hash) && !current.key?('checkpoint')
          validate!(current,account)
          raise Publication::Invalid,:invalid_lease_checkpoint unless %w[acquire renew].include?(current['action']) &&
            current['expires_at']>snapshot['observed_at'] && current['expires_at']<=snapshot['observed_at']+TTL+ServerReadinessService::STAMP_SKEW
        end
      end
      true
    end

    def now!
      value=@clock.call
      raise Publication::Invalid,:invalid_clock unless Data.integer?(value)
      value
    end

    def check!
      @changed=true unless Data.account(@user.call).downcase==@owner
      raise ServerPlanArchive::ContextChanged,'Account changed' if @changed
      true
    end
  end
end
