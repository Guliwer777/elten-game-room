# encoding: UTF-8
require_relative 'server_readiness_service'
require_relative 'local_registration_time'
require_relative 'match_order'

module GameRoomTournaments
  # Append-only observations for an explicit, single-organizer pilot.
  # No atomic consent port, occupancy claim, notification backend or start grant.
  class ServerProposalService
    Data=Publication::Data
    KIND='tournament-pilot-proposal-v1'.freeze
    RESPONSE='tournament-pilot-response-v1'.freeze
    def initialize(table:,journal:,user:,source:,readiness:,clock:,guard:-> {true})
      @table,@journal,@user,@source,@readiness,@clock,@guard=table,journal,user,source,readiness,clock,guard
      @owner,@changed=journal.owner,false
      account!
    end

    def propose(match_id:,leg:,intent_id:)
      source=scope!(match_id,leg)
      raise Publication::Invalid,:not_coordinator unless @owner==source['candidate']['publication_ref']['author']
      prior=snapshot(match_id:match_id,leg:leg)
      raise Publication::Invalid,:proposal_pending unless %w[missing expired declined].include?(prior['state'])
      ready=ready!(source)
      now=clock!
      window=window!(source,now)
      closes=([window['closes']]+ready.values.map{|row|row['expires_at']}).min
      Data.key!(intent_id)
      document={'kind'=>KIND,'publication_ref'=>source['candidate']['publication_ref'],
        'schedule_id'=>source['candidate']['schedule_id'],'match'=>source['match'],'ready'=>ready,
        'window'=>{'opens'=>now,'closes'=>closes},'nonce'=>intent_id}
      write(document,source,'proposal',@owner,intent_id) do
        fresh=scope!(match_id,leg)
        fresh==source && ready!(fresh)==ready && clock!<closes
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
        proposal,stored_token=latest(anchor(fresh,'proposal',fresh['candidate']['publication_ref']['author']),fresh['candidate']['publication_ref']['author'])
        fresh==source && stored_token==token && proposal && proposal['ready']==ready!(fresh) && clock!<proposal['window']['closes']
      end
      snapshot(match_id:match_id,leg:leg)
    end

    def snapshot(match_id:,leg:)
      source=scope!(match_id,leg)
      empty={'state'=>'missing','token'=>nil,'accepted'=>[],'declined'=>[],'players'=>source['match']['players'],
        'start_allowed'=>false,'dispatch_allowed'=>false,'finalize_allowed'=>false}
      document,token=latest(anchor(source,'proposal',source['candidate']['publication_ref']['author']),source['candidate']['publication_ref']['author'])
      return Data.freeze_tree(empty) unless document
      validate!(document,source,KIND)
      ready=ready!(source)
      unless document['ready']==ready && document['window']['opens']<=clock! && clock!<document['window']['closes']
        return Data.freeze_tree(empty.merge('state'=>'expired','token'=>token))
      end
      accepted,declined=[],[]
      source['match']['players'].each do |person|
        response,_digest=latest(anchor(source,token,person),person)
        next unless response
        validate!(response,source,RESPONSE)
        raise Publication::Invalid,:invalid_proposal_response unless response['account']==person && response['token']==token
        (response['accept'] ? accepted : declined)<<person
      end
      raise ServerPlanArchive::ContextChanged,'Tournament source changed' unless scope!(match_id,leg)==source
      state=declined.empty? ? accepted.size==source['match']['players'].size ? 'consented' : 'awaiting_consent' : 'declined'
      Data.freeze_tree(empty.merge('state'=>state,'token'=>token,'accepted'=>accepted,'declined'=>declined))
    rescue Publication::Invalid => error
      raise unless error.code==:players_not_ready
      Data.freeze_tree(empty.merge('state'=>'expired'))
    end

    # Readback never creates another attempt, even after proposal expiry.
    def reconcile(id)
      record=@journal.fetch(id)
      raise OperationJournal::Invalid,:missing_plan_operation unless record && record['kind']=='plan_document'
      document=StrictJson.parse(record['values']['document_json'],max_nesting:12)
      match=document.fetch('match')
      source=scope!(match['match_id'],match['leg'])
      archive(document,source,record['values']['operation_key']).reconcile(id)
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
            (document['kind']!=KIND || @owner==source['candidate']['publication_ref']['author']) &&
            (document['kind']!=RESPONSE || document['account']==@owner) && (!boundary || boundary.call)
        })
    end

    def latest(retained,author)
      rows=@table.select(where:{'operation_key'=>retained['operation_key']},order:[['__id','desc']],limit:1000).to_a
      account!
      raise Publication::Invalid,:proposal_read_limit if rows.size>=1000
      rows=Data.copy(rows,max_bytes:4_194_304,max_nodes:32_768,max_depth:8)
      return [nil,nil] if rows.empty?
      rows.each{|row|Data.metadata(row)}
      raise Publication::Invalid,:duplicate_proposal_row unless rows.map{|r|r['__id']}.uniq.size==rows.size
      headers=rows.select{|r|r['part_index']==0}
      raise Publication::Invalid,:incomplete_proposal unless rows.all?{|r|headers.any?{|h|h['document_digest']==r['document_digest']}}
      header=headers.max_by{|r|r['__id']}
      raise Publication::Invalid,:incomplete_proposal unless header && header['__insertion_time']<=clock!
      parts=rows.select{|r|r['document_digest']==header['document_digest']}
      [ServerPlanDocument.decode(parts,anchor:retained,author:author),header['document_digest']]
    end

    def ready!(source)
      snapshot=@readiness.snapshot
      raise Publication::Invalid,:players_not_ready unless snapshot['schedule_id']==source['candidate']['schedule_id']
      source['match']['players'].to_h do |person|
        row=snapshot['participants'].find{|r|r['account']==person}
        unless row && row['state']=='ready' && Data.integer?(row['expires_at']) && row['expires_at']>clock!
          raise Publication::Invalid,:players_not_ready
        end
        ServerPlanDocument.digest!(row['revision'])
        [person,row.slice('revision','expires_at')]
      end
    end

    def scope!(id,leg)
      account!
      raise ServerPlanArchive::ContextChanged,'View changed' unless @guard.call
      ServerPlanDocument.digest!(id)
      raise Publication::Invalid,:invalid_proposal_leg unless [1,2].include?(leg)
      source=@source.call
      candidate=source.fetch('candidate')
      match=candidate.fetch('matches').find{|r|r['match_id']==id && r['leg']==leg}
      unless match && !match.key?('unit_ids') && match['players'].is_a?(Array) && match['players'].size.between?(2,8) &&
          match['players'].uniq==match['players'] && (match['players']-candidate['roster']).empty? &&
          match['players'].all?{|person|Data.account(person).downcase==person} &&
          candidate['state']=='observed_candidate' && candidate['finality']=='unknown' &&
          %w[start_allowed dispatch_allowed finalize_allowed].all?{|key|candidate[key]==false}
        raise Publication::Invalid,:invalid_proposal_source
      end
      value=Data.copy({'tournament_id'=>source['tournament_id'],
        'candidate'=>candidate.slice('publication_ref','schedule_id','publication_digest','roster_generation','timezone','windows'),
        'match'=>match.slice('match_id','leg','players').merge('players'=>MatchOrder.players(candidate['matches'],match))},max_bytes:262_144,max_nodes:16_384,max_depth:12)
      account!
      Data.freeze_tree(value)
    end

    def anchor(source,role,person)
      candidate=source['candidate']
      value={'tournament_id'=>source['tournament_id'],'publication_digest'=>candidate['publication_digest'],
        'roster_generation'=>candidate['roster_generation'],'operation_key'=>Digest::SHA256.hexdigest(JSON.generate(
          ['pilot-proposals-v1',@journal.backend_identity,source['tournament_id'],candidate['schedule_id'],source['match']['match_id'],source['match']['leg'],role,person]))}
      ServerPlanDocument.anchor!(value)
      value
    end

    def validate!(value,source,kind)
      keys=kind==KIND ? %w[kind publication_ref schedule_id match ready window nonce] : %w[kind publication_ref schedule_id match token account accept nonce]
      unless [KIND,RESPONSE].include?(kind) && value.keys.sort==keys.sort && value['kind']==kind &&
          value['publication_ref']==source['candidate']['publication_ref'] && value['schedule_id']==source['candidate']['schedule_id'] && value['match']==source['match']
        raise Publication::Invalid,:invalid_pilot_document
      end
      Data.key!(value['nonce'])
      if kind==KIND
        raise Publication::Invalid,:invalid_pilot_window unless value['window'].is_a?(Hash) && value['window'].keys.sort==%w[closes opens] &&
          Data.integer?(value['window']['opens']) && Data.integer?(value['window']['closes']) && value['window']['opens']<value['window']['closes']
      else
        ServerPlanDocument.digest!(value['token'])
        raise Publication::Invalid,:invalid_proposal_response unless [true,false].include?(value['accept']) && source['match']['players'].include?(value['account'])
      end
    end

    def window!(source,now)
      candidate=source['candidate']
      windows=candidate.fetch('windows').map do |civil|
        {'opens'=>LocalRegistrationTime.convert_in_zone(civil['date'],civil['start'],timezone:candidate['timezone']),
          'closes'=>LocalRegistrationTime.convert_in_zone(civil['end_date'],civil['end'],timezone:candidate['timezone'])}
      end
      windows.find{|window|window['opens']<=now && now<window['closes']} || (raise Publication::Invalid,:outside_window)
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
