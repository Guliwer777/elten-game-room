# encoding: UTF-8
require_relative 'server_readiness_service'
require_relative 'local_registration_time'
require_relative 'match_order'
require_relative 'ordinary_team_players'
require_relative 'server_match_window'

module GameRoomTournaments
  # Explicit match invitations. Any planned player may invite the others;
  # the ordinary table still has one fixed creator (the first planned seat).
  # The SDK has no CAS; consent is rechecked before native table entry and is
  # not an atomic server reservation. Notifications only carry references.
  class ServerProposalService
    Data=Publication::Data
    KIND='tournament-match-invitation-v2'.freeze
    RESPONSE='tournament-match-response-v2'.freeze
    CONSENT_SECONDS=300
    def initialize(table:,journal:,user:,source:,readiness:,clock:,guard:-> {true},registry:nil)
      @table,@journal,@user,@source,@readiness,@clock,@guard=table,journal,user,source,readiness,clock,guard
      @owner,@changed=journal.owner,false
      @registry=registry
      account!
    end

    def propose(match_id:,leg:,intent_id:)
      source=scope!(match_id,leg)
      raise Publication::Invalid,:not_a_match_player unless source['match']['players'].include?(@owner)
      prior=snapshot(match_id:match_id,leg:leg)
      raise Publication::Invalid,:proposal_pending unless %w[missing expired declined].include?(prior['state'])
      now=clock!
      window=window!(source,now)
      closes=[window['closes'],now+CONSENT_SECONDS].compact.min
      Data.key!(intent_id)
      document={'kind'=>KIND,'publication_ref'=>source['candidate']['publication_ref'],
        'schedule_id'=>source['candidate']['schedule_id'],'match'=>source['match'],'sender'=>@owner,
        'window'=>{'opens'=>now,'closes'=>closes},'nonce'=>intent_id}
      write(document,source,'proposal',@owner,intent_id) do
        fresh=scope!(match_id,leg)
        fresh==source && clock!<closes
      end
      snapshot(match_id:match_id,leg:leg)
    end

    def respond(match_id:,leg:,token:,accept:,intent_id:)
      raise ArgumentError,'Boolean response required' unless [true,false].include?(accept)
      source=scope!(match_id,leg)
      raise Publication::Invalid,:not_a_match_player unless source['match']['players'].include?(@owner)
      current=snapshot(match_id:match_id,leg:leg)
      unless %w[awaiting_consent consented].include?(current['state']) && current['token']==token && (!accept || !current['accepted'].include?(@owner))
        raise Publication::Invalid,:proposal_changed
      end
      Data.key!(intent_id)
      document={'kind'=>RESPONSE,'publication_ref'=>source['candidate']['publication_ref'],
        'schedule_id'=>source['candidate']['schedule_id'],'match'=>source['match'],'token'=>token,
        'account'=>@owner,'accept'=>accept,'nonce'=>intent_id}
      write(document,source,token,@owner,intent_id) do
        fresh=scope!(match_id,leg)
        proposal,stored_token=latest(anchor(fresh,'proposal',nil),nil,authors:fresh['match']['players'])
        fresh==source && stored_token==token && proposal && clock!<proposal['window']['closes']
      end
      snapshot(match_id:match_id,leg:leg)
    end

    def snapshot(match_id:,leg:)
      source=scope!(match_id,leg)
      empty={'state'=>'missing','token'=>nil,'accepted'=>[],'declined'=>[],'players'=>source['match']['players'],
        'start_allowed'=>false,'dispatch_allowed'=>false,'finalize_allowed'=>false}
      document,token=latest(anchor(source,'proposal',nil),nil,authors:source['match']['players'])
      return Data.freeze_tree(empty) unless document
      validate!(document,source,KIND)
      accepted,declined=[document['sender']],[]
      keys=source['match']['players'].to_h{|person|[person,anchor(source,token,person)]}
      responses=ServerDocumentRows.read(@table,where:{'operation_key'=>{'in'=>keys.values.map{|key|key['operation_key']}}},
        guard:method(:account!)).group_by{|row|row['operation_key']}
      source['match']['players'].each do |person|
        key=keys.fetch(person)
        response,digest=latest(key,person,partial_response:true,rows:responses.fetch(key['operation_key'],[]))
        accepted.delete(person) if digest && !response
        next unless response
        validate!(response,source,RESPONSE)
        raise Publication::Invalid,:invalid_proposal_response unless response['account']==person && response['token']==token
        accepted.delete(person)
        (response['accept'] ? accepted : declined)<<person
      end
      raise ServerPlanArchive::ContextChanged,'Tournament source changed' unless scope!(match_id,leg)==source
      observed=empty.merge('token'=>token,'accepted'=>accepted,'declined'=>declined,
        'sender'=>document['sender'],'window'=>document['window'])
      unless document['window']['opens']<=clock! && clock!<document['window']['closes']
        return Data.freeze_tree(observed.merge('state'=>'expired','expiry_reason'=>'timeout'))
      end
      state=declined.empty? ? accepted.size==source['match']['players'].size ? 'consented' : 'awaiting_consent' : 'declined'
      Data.freeze_tree(observed.merge('state'=>state))
    end

    # Readback never creates another attempt, even after proposal expiry.
    def reconcile(id)
      record=@journal.fetch(id)
      raise OperationJournal::Invalid,:missing_plan_operation unless record && record['kind']=='plan_document'
      document=StrictJson.parse(record['values']['document_json'],max_nesting:12)
      match=document.fetch('match')
      source=scope!(match['match_id'],match['leg'])
      archive(document,source,record['values']['operation_key']).resume(id)
    end

    private

    def write(document,source,role,person,intent_id,&boundary)
      retained=anchor(source,role,person)
      archive(document,source,retained['operation_key'],boundary).publish(intent_id:'pilot:'+intent_id,document:document,anchor:retained)
    end

    def archive(document,source,key,boundary=nil)
      digest=Digest::SHA256.hexdigest(JSON.generate(ServerPlanDocument.copy_document(document)))
      ServerPlanArchive.new(table:ServerReadinessService::EventTable.new(@table,digest),journal:@journal,user:-> {account!},
        verify:->(value,retained){
          validate!(value,source,document['kind'])
          expected=anchor(source,document['kind']==KIND ? 'proposal' : document['token'],@owner)
          retained==expected && retained['operation_key']==key && scope!(source['match']['match_id'],source['match']['leg'])==source &&
            (document['kind']!=KIND || document['sender']==@owner) &&
            (document['kind']!=RESPONSE || document['account']==@owner) && (!boundary || boundary.call)
        })
    end

    def latest(retained,author,partial_response:false,authors:nil,rows:nil)
      rows ||= ServerDocumentRows.read(@table,where:{'operation_key'=>retained['operation_key']},guard:method(:account!),author:author)
      rows=ServerDocumentRows.owned(rows,author) if author
      rows=rows.select{|row|authors.include?(row['__insertion_user'].to_s.downcase)} if authors
      return [nil,nil] if rows.empty?
      rows.each{|row|Data.metadata(row)}
      raise Publication::Invalid,:duplicate_proposal_row unless rows.map{|r|r['__id']}.uniq.size==rows.size
      headers=rows.select{|r|r['part_index']==0}
      raise Publication::Invalid,:incomplete_proposal unless rows.all?{|r|headers.any?{|h|h['document_digest']==r['document_digest']}}
      header=headers.group_by{|r|r['document_digest']}.values.map{|group|group.min_by{|r|r['__id']}}.max_by{|r|r['__id']}
      raise Publication::Invalid,:incomplete_proposal unless header && header['__insertion_time']<=clock!+ServerReadinessService::STAMP_SKEW
      author=header['__insertion_user'].downcase
      parts=rows.select{|r|r['document_digest']==header['document_digest'] && r['__insertion_user'].downcase==author}
      canonical=ServerPlanDocument.canonical_rows(parts,anchor:retained,author:author)
      if canonical.size<header['part_count']+1 &&
          canonical.all?{|row|row['part_count']==header['part_count']}
        # Other players may confirm concurrently, between this header and its
        # payload. Do not fall back to an earlier response (which might have
        # been acceptance before a new decline), and never count a partial
        # response as consent. A partial proposal itself grants nothing.
        return [nil,header['document_digest']] if partial_response
        raise ServerPlanArchive::Unconfirmed,'Proposal is still being written'
      end
      document=ServerPlanDocument.decode(parts,anchor:retained,author:author)
      raise Publication::Invalid,:invalid_pilot_document if document['kind']==KIND && document['sender']!=author
      [document,header['document_digest']]
    end


    def scope!(id,leg)
      account!
      raise ServerPlanArchive::ContextChanged,'View changed' unless @guard.call
      ServerPlanDocument.digest!(id)
      raise Publication::Invalid,:invalid_proposal_leg unless [1,2].include?(leg)
      source=@source.call
      candidate=source.fetch('candidate')
      match=candidate.fetch('matches').find{|r|r['match_id']==id && r['leg']==leg}
      unless match && match['players'].is_a?(Array) && match['players'].size.between?(2,8) &&
          match['players'].uniq==match['players'] && (match['players']-candidate['roster']).empty? &&
          match['players'].all?{|person|Data.account(person).downcase==person} &&
          candidate['state']=='observed_candidate' && candidate['finality']=='unknown' &&
          %w[start_allowed dispatch_allowed finalize_allowed].all?{|key|candidate[key]==false}
        raise Publication::Invalid,:invalid_proposal_source
      end
      players = if match.key?('unit_ids')
        raise Publication::Invalid,:invalid_proposal_source unless @registry
        OrdinaryTeamPlayers.prepare(candidate:candidate,match:match,registry:@registry)['players'].map{|person|person['account']}
      else
        MatchOrder.players(candidate['matches'],match)
      end
      value=Data.copy({'tournament_id'=>source['tournament_id'],
        'candidate'=>candidate.slice('publication_ref','schedule_id','publication_digest','roster_generation','timezone','windows','starts_at'),
        'match'=>match.slice('match_id','leg','players').merge('players'=>players)},max_bytes:262_144,max_nodes:16_384,max_depth:12)
      account!
      Data.freeze_tree(value)
    end


    def anchor(source,role,person)
      person=nil if role=='proposal'
      candidate=source['candidate']
      value={'tournament_id'=>source['tournament_id'],'publication_digest'=>candidate['publication_digest'],
        'roster_generation'=>candidate['roster_generation'],'operation_key'=>Digest::SHA256.hexdigest(JSON.generate(
          ['match-invitations-v2',@journal.backend_identity,source['tournament_id'],candidate['schedule_id'],source['match']['match_id'],source['match']['leg'],role,person]))}
      ServerPlanDocument.anchor!(value)
      value
    end

    def validate!(value,source,kind)
      keys=kind==KIND ? %w[kind publication_ref schedule_id match sender window nonce] : %w[kind publication_ref schedule_id match token account accept nonce]
      unless [KIND,RESPONSE].include?(kind) && value.keys.sort==keys.sort && value['kind']==kind &&
          value['publication_ref']==source['candidate']['publication_ref'] && value['schedule_id']==source['candidate']['schedule_id'] && value['match']==source['match']
        raise Publication::Invalid,:invalid_pilot_document
      end
      Data.key!(value['nonce'])
      if kind==KIND
        raise Publication::Invalid,:invalid_pilot_window unless value['window'].is_a?(Hash) && value['window'].keys.sort==%w[closes opens] &&
          Data.integer?(value['window']['opens']) && Data.integer?(value['window']['closes']) && value['window']['opens']<value['window']['closes']
        raise Publication::Invalid,:not_a_match_player unless source['match']['players'].include?(value['sender'])
      else
        ServerPlanDocument.digest!(value['token'])
        raise Publication::Invalid,:invalid_proposal_response unless [true,false].include?(value['accept']) && source['match']['players'].include?(value['account'])
      end
    end

    def window!(source,now)
      ServerMatchWindow.current(source['candidate'],now)
    end

    def clock!
      value=@clock.call
      raise Publication::Invalid,:invalid_clock unless Data.integer?(value)
      value
    end

    def account!
      account=Data.account(@user.call).downcase
      @changed=true unless account==@owner
      raise ServerPlanArchive::ContextChanged,'Account changed' if @changed
      raise ServerPlanArchive::ContextChanged,'View changed' unless @guard.call
      account
    rescue Publication::Invalid
      @changed=true
      raise ServerPlanArchive::ContextChanged,'Account unavailable'
    end
  end
end
