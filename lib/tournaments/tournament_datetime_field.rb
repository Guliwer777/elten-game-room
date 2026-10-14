# encoding: UTF-8
require 'date'
require_relative '../game_content'
require_relative '../game_room_localization'

module GameRoomTournaments
  # One native list on the Tab path; arrow keys choose a part and its value.
  class TournamentDateTimeField
    using GameRoomLocalization::Translations
    attr_reader :fields
    def initialize(time:, label:, parts: :datetime)
      @values=[time.year,time.month,time.day,time.hour,time.min]
      @parts=case parts
      when :date then (0..2).to_a
      when :time then (3..4).to_a
      else (0..4).to_a
      end
      @part=@parts.first
      @label=GameRoomContent.utf8(label)
      @labels=[_("Year"),_("Month"),_("Day"),_("Hour"),_("Minute")].map{|s|GameRoomContent.utf8(s)}
      @control=ListBox.new([],header:@label,quiet:true)
      @fields=[@control]
      refresh
      @control.on(:move) do
        @values[@part]=choices[@control.index]
        @values[2]=[@values[2],Date.new(@values[0],@values[1],-1).day].min
        update_header
      end
      {key_left:-1,key_right:1}.each do |key,direction|
        @control.on(key) do |modifiers|
          next if modifiers.any? || raw_key_held?(:key_insert)
          target=@part+direction
          next unless @parts.include?(target)
          @part=target
          refresh
          @control.focus(nil,nil,@labels[@part])
        end
      end
    end
    def date; format('%04d-%02d-%02d',*@values.take(3)); end
    def time; format('%02d:%02d',*@values.last(2)); end
    def label=(value)
      @label=GameRoomContent.utf8(value)
      update_header
    end
    private
    def choices
      case @part
      when 0 then (1..9999).to_a
      when 1 then (1..12).to_a
      when 2 then (1..Date.new(@values[0],@values[1],-1).day).to_a
      when 3 then (0..23).to_a
      else (0..59).to_a
      end
    end
    def refresh
      values=choices
      @control.options=values.map{|v|format(@part==0 ? '%04d' : '%02d',v)}
      @control.index=values.index(@values[@part])
      update_header
    end
    def update_header
      value=@parts==(0..2).to_a ? date : @parts==(3..4).to_a ? time : "#{date} #{time}"
      @control.header="#{@label}: #{value}; #{@labels[@part]}"
    end
  end
end
