# encoding: UTF-8
require_relative 'tournament_start_notice'
require_relative 'schedule_source'
require_relative 'phase_description'

module GameRoomTournaments
  # Registration invitations and final standings are information, never
  # participant consent or permission to create/start a table.
  class TournamentEventNotice < TournamentStartNotice
    TYPES={'registration'=>'game_room.tournament_registration','finished'=>'game_room.tournament_finished',
      'phase_finished'=>'game_room.tournament_phase_finished'}.freeze
    LIFETIME=7*86400

    def self.metadata(raw)
      value=Data.copy(raw,max_bytes:2048,max_nodes:64,max_depth:4)
      fields=FIELDS+DESCRIPTION_FIELDS+%w[kind issued_at]
      fields=fields+['phase_id'] if value.is_a?(Hash) && value['kind']=='phase_finished'
      unless value.is_a?(Hash) && value.keys.sort==fields.sort &&
          value['version']==1 && TYPES.key?(value['kind']) && Data.integer?(value['issued_at'],1)
        raise Publication::Invalid,:invalid_tournament_notice
      end
      Data.text!(value['title'],bytes:1024)
      Data.text!(value['game'],bytes:128)
      Data.text!(value['backend_identity'],bytes:256)
      reference=ScheduleSource.reference(value['publication_ref'])
      value['publication_ref']=reference
      value['recipient']=Data.account(value['recipient']).downcase
      Data.key!(value['phase_id']) if value['kind']=='phase_finished'
      expected=event_id(value)
      raise Publication::Invalid,:invalid_tournament_notice unless value['event_id']==expected
      Data.freeze_tree(value)
    end

    def self.event_id(value)
      identity=['tournament-event-v1',value['kind'],value['backend_identity'],value['publication_ref']]
      identity << value['issued_at'] if value['kind']=='registration'
      identity << value['phase_id'] if value['kind']=='phase_finished'
      Digest::SHA256.hexdigest(JSON.generate(identity))
    end

    def initialize(kind:,**arguments)
      raise ArgumentError,'Unknown tournament notice' unless TYPES.key?(kind)
      @kind=kind
      super(**arguments)
    end

    def notices(publication_ref:,recipient:nil,phase_id:nil,addressed:false)
      current!
      reference=ScheduleSource.reference(publication_ref)
      proof=source!(reference,delivery:true,phase_id:phase_id)
      raise ProposalNotice::Stale,'Not tournament organizer' unless proof['sender']==@scope['account']
      people=@kind=='registration' ? [Data.account(recipient).downcase] : proof['participants']
      people.map do |person|
        check_recipient!(proof,person)
        metadata={'version'=>1,'kind'=>@kind,'issued_at'=>proof['issued_at'],'backend_identity'=>@scope['backend_identity'],
          'publication_ref'=>reference,'recipient'=>person,'title'=>proof['title'],'game'=>proof['game'],
          'event_id'=>nil}
        metadata['phase_id']=phase_id if @kind=='phase_finished'
        metadata['event_id']=self.class.event_id(metadata)
        metadata=self.class.metadata(metadata)
        name=@kind=='registration' ? Data.account(recipient) : RegistrationProjection.delivery_name(proof['usernames'],person) if addressed
        addressed ? [metadata,name].freeze : metadata
      end.freeze
    end

    def inspect(metadata:,sender:,delivery:false)
      current!
      notice=self.class.metadata(metadata)
      sender=Data.account(sender).downcase
      unless notice['kind']==@kind && notice['backend_identity']==@scope['backend_identity'] &&
          (delivery ? sender==@scope['account'] : notice['recipient']==@scope['account'])
        raise ProposalNotice::Stale,'Different tournament notice scope'
      end
      proof=source!(notice['publication_ref'],delivery:delivery,issued_at:notice['issued_at'],phase_id:notice['phase_id'])
      raise ProposalNotice::Stale,'Wrong organizer or changed description' unless sender==proof['sender'] && notice.slice(*DESCRIPTION_FIELDS)==proof.slice(*DESCRIPTION_FIELDS)
      check_recipient!(proof,notice['recipient'])
      current!
      Data.freeze_tree(proof.merge('metadata'=>notice))
    end

    def description(metadata:,sender:)
      current!
      notice=self.class.metadata(metadata)
      return unless notice['kind']==@kind && notice['backend_identity']==@scope['backend_identity'] &&
        notice['recipient']==@scope['account'] && Data.account(sender).downcase==notice['publication_ref']['author']
      notice.slice(*DESCRIPTION_FIELDS)
    end

    def delivery_identity(notice)
      notice.slice(*(FIELDS+%w[kind phase_id]))
    end

    def retention_deadline
      current!
      now!+LIFETIME
    end

    private

    def check_recipient!(proof,person)
      if @kind=='registration'
        raise ProposalNotice::Stale,'Already registered or tournament full' if proof['participants'].include?(person) || proof['full']
      else
        raise ProposalNotice::Stale,'Not a participant' unless proof['participants'].include?(person)
      end
    end

    def source!(reference,delivery:,issued_at:nil,phase_id:nil)
      raise ProposalNotice::Unavailable,'Tournament notice source is not connected' unless @source
      raw=@kind=='phase_finished' ? @source.call(reference,phase_id) : @source.call(reference)
      value=Data.copy(raw,max_bytes:262_144,max_nodes:16_384,max_depth:12)
      current!
      row=value['publication']
      raise ProposalNotice::Stale,'Tournament unavailable' unless row && row['__insertion_user'].downcase==reference['author'] && row['publication_key']==reference['publication_key']
      people=value.fetch('people')
      unless people.is_a?(Array) && people.size.between?(1,256) && people.uniq==people && people.all?{|person|Data.account(person).downcase==person}
        raise ProposalNotice::Stale,'Invalid registered roster'
      end
      now=now!
      raise ProposalNotice::Stale,'Notice from the future' if issued_at && issued_at>now+5
      proof={'sender'=>reference['author'],'title'=>row['title'],'game'=>row['game'],'participants'=>people,
        'usernames'=>value['usernames'],
        'publication_digest'=>RegistrationProjection.publication_generation(row)}
      if @kind=='registration'
        raise ProposalNotice::Stale,'Registration not open' unless TournamentTiming.registration_open?(row,now)
        settings=JSON.parse(row['settings_json'])
        proof['full']=!!(settings['participant_limit'] && value.fetch('members').size>=settings['participant_limit'])
        proof['starts_at']=row['registration_opens_at']
        proof['issued_at']=issued_at || now
        proof['expires_at']=[proof['issued_at']+LIFETIME,TournamentTiming.closes_at(row)].compact.min
      elsif @kind=='phase_finished'
        transition=value['transition']
        raise ProposalNotice::Stale,'Phase not completed' unless transition && transition['phase_id']==phase_id && Data.integer?(transition['completed_at'],1)
        proof['starts_at']=proof['issued_at']=transition['completed_at']
        raise ProposalNotice::Stale,'Phase completion changed' if issued_at && issued_at!=proof['issued_at']
        proof['expires_at']=proof['issued_at']+LIFETIME
        proof.merge!(transition.slice('phase','next_phase'))
      else
        results=value.fetch('results')
        raise ProposalNotice::Stale,'Tournament not finished' unless results['completed']==true && Data.integer?(results['completed_at'],1)
        proof['starts_at']=results['completed_at']
        proof['issued_at']=results['completed_at']
        raise ProposalNotice::Stale,'Completion changed' if issued_at && issued_at!=proof['issued_at']
        proof['expires_at']=results['completed_at']+LIFETIME
        proof['winners']=value.fetch('winners')
      end
      raise ProposalNotice::Stale,'Tournament notice expired' unless now<proof['expires_at']
      Data.freeze_tree(Data.copy(proof,max_bytes:262_144,max_nodes:16384,max_depth:12))
    end
  end
end
