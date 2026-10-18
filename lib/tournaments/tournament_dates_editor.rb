# encoding: UTF-8
require_relative 'ui_dialogs'
require_relative 'tournament_datetime_field'
require_relative 'tournament_timing'

module GameRoomTournaments
  class TournamentDatesEditor < Dialogs::Window
    using GameRoomLocalization::Translations

    def self.values(publication)
      return {'opens'=>nil,'closes'=>0,'starts'=>0,'deadline'=>0,'windows'=>[]} unless publication
      values={'opens'=>publication['registration_opens_at'],'closes'=>publication['registration_closes_at'],
        'starts'=>TournamentTiming.starts_at(publication) || 0,'deadline'=>TournamentTiming.deadline_at(publication) || 0,'windows'=>[]}
      hours=TournamentTiming.schedule(publication)['daily_hours']
      values['daily_hours']=Publication::Data.copy(hours) if hours
      values
    end

    def initialize(program:,values:,alert:,clock:)
      @program,@alert,@clock=program,alert,clock
      @values=Publication::Data.copy(values)
    end

    private

    def build_form
      now=Time.at(@clock.call).getlocal
      introduction=readonly(_("Dates and playing hours"),_("Dates are optional. Without a date, you open or close registration and start the tournament yourself. The final deadline is a reminder, not an automatic result."))
      @opening=ListBox.new([_("Immediately"),_("At a chosen time"),_("Manually by the organizer")].map{|s|text(s)},
        header:text(_("Open registration")),index:@values['opens'].nil? ? 0 : @values['opens']==0 ? 2 : 1,flags:ListBox::Flags::AnyDir,quiet:true)
      @open_date=TournamentDateTimeField.new(time:@values['opens'].to_i>0 ? Time.at(@values['opens']).getlocal : now,label:text(_("Registration opens")))
      @dates={}
      @scheduled={}
      [['closes',_("Schedule the close of registration"),_("Registration closes")],
        ['starts',_("Schedule the tournament start"),_("Tournament starts")],
        ['deadline',_("Set an optional deadline"),_("Tournament deadline")]].each do |key,label,date_label|
        @scheduled[key]=CheckBox.new(text(label),checked:@values[key]>0)
        @dates[key]=TournamentDateTimeField.new(time:@values[key]>0 ? Time.at(@values[key]).getlocal : now+3600,label:text(date_label))
      end
      hours=@values['daily_hours']
      @limited=CheckBox.new(text(_("Limit playing hours")),checked:!hours.nil?)
      @daily_start=time_field(hours && hours['start'] || '18:00',_("Daily start time"))
      @daily_end=time_field(hours && hours['end'] || '22:00',_("Daily end time"))
      @offsets=(-720..840).step(15).to_a
      offset=hours ? hours['utc_offset_minutes'] : now.utc_offset/60
      @zone=ListBox.new(@offsets.map{|n|TournamentTiming.offset_label(n)},header:text(_("Time zone (fixed UTC offset)")),
        index:@offsets.index(offset) || @offsets.index(0),flags:ListBox::Flags::AnyDir,quiet:true)
      @hours_help=readonly(_("Playing hours"),_("The same hours apply every day. An end time earlier than the start time means the following day. The selected UTC offset does not change with daylight saving time. Games already started may continue."))
      save=button(_("Use these settings")){save_dates}
      back=button(_("Cancel"))
      fields=[introduction,@opening,*@open_date.fields]
      @dates.each{|key,part|fields.concat([@scheduled[key],*part.fields])}
      @hour_fields=[*@daily_start.fields,*@daily_end.fields,@zone,@hours_help]
      make_form(fields+[@limited,*@hour_fields,save,back],cancel:back)
      @form.accept_button=save
      @opening.on(:move){interaction(focus:false){update_visibility}}
      [*@scheduled.values,@limited].each{|control|control.on(:change){interaction(focus:false){update_visibility}}}
      update_visibility
    end

    def update_visibility
      @open_date.fields.each{|field|@opening.index==1 ? @form.show(field) : @form.hide(field)}
      @dates.each{|key,part|part.fields.each{|field|@scheduled[key].checked ? @form.show(field) : @form.hide(field)}}
      @hour_fields.each{|field|@limited.checked ? @form.show(field) : @form.hide(field)}
    end

    def time_field(value,label)
      h,m=value.split(':').map(&:to_i)
      TournamentDateTimeField.new(time:Time.utc(2000,1,1,h,m),label:text(label),parts: :time)
    end

    def save_dates
      values=@values.merge('windows'=>[],'opens'=>case @opening.index
        when 0 then nil
        when 1 then LocalRegistrationTime.convert(@open_date.date,@open_date.time)
        else 0
        end)
      @dates.each do |key,part|
        values[key]=@scheduled[key].checked ? LocalRegistrationTime.convert(part.date,part.time) : 0
      end
      values.delete('daily_hours')
      values['daily_hours']={'start'=>@daily_start.time,'end'=>@daily_end.time,'utc_offset_minutes'=>@offsets.fetch(@zone.index)} if @limited.checked
      row={'schema_version'=>2,'registration_opens_at'=>values['opens'] || @clock.call,'registration_closes_at'=>values['closes']}
      if values['starts']>0 && values['deadline']>0 && values['deadline']<values['starts']
        raise Publication::Invalid,:deadline_before_start
      end
      schedule={'windows'=>[],'starts_at'=>values['starts'],'deadline_at'=>values['deadline']}
      schedule['daily_hours']=values['daily_hours'] if values['daily_hours']
      TournamentTiming.validate!(row,schedule)
      finish(values)
    rescue Publication::Invalid=>error
      message=case error.code
      when :registration_after_start then _("Registration must close no later than the tournament starts.")
      when :deadline_before_start then _("The deadline cannot be earlier than the tournament start.")
      when :invalid_playing_hours then _("Choose different start and end times, or turn off the playing-hours limit.")
      else _("Registration cannot close before it opens.")
      end
      @alert.call(text(message))
    rescue LocalRegistrationTime::Invalid=>error
      @alert.call(error.message)
    end
  end
end
