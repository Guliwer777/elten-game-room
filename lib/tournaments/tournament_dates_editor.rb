# encoding: UTF-8
require_relative 'ui_dialogs'
require_relative 'tournament_datetime_field'
require_relative 'draft_details_editor'
require_relative 'playing_days'

module GameRoomTournaments
  class TournamentDatesEditor < Dialogs::Window
    using GameRoomLocalization::Translations

    def self.values(publication)
      return {'opens'=>nil,'closes'=>0,'starts'=>0,'deadline'=>0,'windows'=>[]} unless publication
      {'opens'=>publication['registration_opens_at'],'closes'=>publication['registration_closes_at'],
        'starts'=>TournamentTiming.starts_at(publication) || 0,'deadline'=>TournamentTiming.deadline_at(publication) || 0,
        'windows'=>PlayingDays.local_intervals(TournamentTiming.schedule(publication)['windows'],timezone:publication['timezone']).map do |first,last|
          LocalRegistrationTime.utc_window(first.to_i,last.to_i)
        end}
    end

    def initialize(program:,values:,alert:,clock:)
      @program,@alert,@clock=program,alert,clock
      @values=Publication::Data.copy(values)
    end

    private

    def build_form
      now=Time.at(@clock.call).getlocal
      introduction=readonly(_("Dates and playing hours"),_("Dates are optional. Without a date, you open or close registration and start the tournament yourself. The final deadline is a reminder, not an automatic result."))
      @opening=ListBox.new([_("Immediately"),_("At a chosen time"),_("When I open registration")].map{|s|text(s)},
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
      @limited=CheckBox.new(text(_("Limit playing hours")),checked:!@values['windows'].empty?)
      @windows=ListBox.new([],header:text(_("Playing windows")),quiet:true)
      @keys=@values['windows'].each_index.to_a
      @next_key=@keys.size
      @add=button(_("Add window")){change_window}
      @edit=button(_("Edit window")){change_window(@windows.index)}
      @remove=button(_("Remove window")) do
        @values['windows'].delete_at(@windows.index)
        @keys.delete_at(@windows.index)
        render_windows
      end
      save=button(_("Use these settings")){save_dates}
      back=button(_("Cancel"))
      fields=[introduction,@opening,*@open_date.fields]
      @dates.each{|key,part|fields.concat([@scheduled[key],*part.fields])}
      make_form(fields+[@limited,@windows,@add,@edit,@remove,save,back],cancel:back)
      @form.accept_button=save
      @opening.on(:move){interaction(focus:false){update_visibility}}
      [*@scheduled.values,@limited].each{|control|control.on(:change){interaction(focus:false){update_visibility}}}
      render_windows
      update_visibility
    end

    def update_visibility
      @open_date.fields.each{|field|@opening.index==1 ? @form.show(field) : @form.hide(field)}
      @dates.each{|key,part|part.fields.each{|field|@scheduled[key].checked ? @form.show(field) : @form.hide(field)}}
      [@windows,@add,@edit,@remove].each{|field|@limited.checked ? @form.show(field) : @form.hide(field)}
    end

    def render_windows
      labels=PlayingDays.local_intervals(@values['windows'],timezone:'UTC').map do |first,last|
        first,last=first.getlocal,last.getlocal
        "#{first.strftime('%Y-%m-%d %H:%M')} — #{last.strftime('%Y-%m-%d %H:%M')}"
      end
      @windows.update_options(labels,keys:@keys)
    end

    def change_window(index=nil)
      intervals=PlayingDays.local_intervals(@values['windows'],timezone:'UTC')
      local=intervals.map do |first,last|
        first,last=first.getlocal,last.getlocal
        {'date'=>first.strftime('%Y-%m-%d'),'start'=>first.strftime('%H:%M'),'end_date'=>last.strftime('%Y-%m-%d'),'end'=>last.strftime('%H:%M')}
      end
      return if index && !local[index]
      selected=DraftDetailsEditor::WindowEditor.new(program:@program,window:index ? local[index] : {},windows:local,index:index,alert:@alert).wait
      return unless selected
      first=LocalRegistrationTime.convert(selected['date'],selected['start'])
      last=LocalRegistrationTime.convert(selected['end_date'],selected['end'])
      window=LocalRegistrationTime.utc_window(first,last)
      if index
        @values['windows'][index]=window
      else
        @values['windows']<<window
        @keys<<@next_key
        @next_key+=1
      end
      render_windows
    rescue LocalRegistrationTime::Invalid=>error
      @alert.call(error.message)
    end

    def save_dates
      values=@values.merge('opens'=>case @opening.index
        when 0 then nil
        when 1 then LocalRegistrationTime.convert(@open_date.date,@open_date.time)
        else 0
        end)
      @dates.each do |key,part|
        values[key]=@scheduled[key].checked ? LocalRegistrationTime.convert(part.date,part.time) : 0
      end
      values['windows']=[] unless @limited.checked
      if @limited.checked && values['windows'].empty?
        @alert.call(text(_("Add at least one playing window or turn off the playing-hours limit.")))
        return
      end
      row={'schema_version'=>2,'registration_opens_at'=>values['opens'] || @clock.call,'registration_closes_at'=>values['closes']}
      if values['starts']>0 && values['deadline']>0 && values['deadline']<values['starts']
        raise Publication::Invalid,:deadline_before_start
      end
      TournamentTiming.validate!(row,{'windows'=>values['windows'],'starts_at'=>values['starts'],'deadline_at'=>values['deadline']})
      finish(values)
    rescue Publication::Invalid=>error
      message=case error.code
      when :registration_after_start then _("Registration must close no later than the tournament starts.")
      when :deadline_before_start then _("The deadline cannot be earlier than the tournament start.")
      else _("Registration cannot close before it opens.")
      end
      @alert.call(text(message))
    rescue LocalRegistrationTime::Invalid=>error
      @alert.call(error.message)
    end
  end
end
