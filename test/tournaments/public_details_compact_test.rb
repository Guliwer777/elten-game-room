require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/tournament_public_ui'
require_relative '../../lib/tournaments/public_text'
GameRoomLocalization.boot(settings:{'interface_language'=>'en','known_languages'=>['en']})
u=TournamentPublicUI
publication=u.publication.merge('rules'=>"First rule\r\n\r\nSecond rule")
text=GameRoomTournaments::PublicText.new(registry:GameRoomGames::CATALOG,mode_label:'Server trial',actor:'guliwer')
description=text.description(publication,u.snapshot)
raise 'Blank detail lines remain' if description.split(/\r?\n/).any?{|line|line.strip.empty?}
raise 'Rule content lost' unless description.include?('First rule') && description.include?('Second rule')
raise 'Title lost' unless description.include?(publication.fetch('title'))
puts 'PASS compact tournament details preserve content and remove empty lines'
