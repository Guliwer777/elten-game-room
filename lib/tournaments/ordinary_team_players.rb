# encoding: UTF-8
require_relative 'fixed_team_seats'
require_relative 'match_order'

module GameRoomTournaments::OrdinaryTeamPlayers
  # Pure preparation only: no admission, table creation, writes or dispatch.
  def self.prepare(candidate:, match:, registry:)
    data=GameRoomTournaments::Publication::Data
    input=data.copy(candidate,max_bytes:262144,max_nodes:16384,max_depth:16)
    selected=input.fetch('matches').find{|row|row['match_id']==match['match_id'] && row['leg']==match['leg']}
    raise GameRoomTournaments::Publication::Invalid,:source_changed unless selected==match
    roster=input.fetch('roster').map{|account|{'account'=>account,'username'=>account}}
    seats=GameRoomTournaments::FixedTeamSeats
    membership=seats.membership(input.fetch('membership'),roster)
    size=seats.unit_size(membership)
    template=seats.template(input.fetch('team_template'),options:input.fetch('game_options'),unit_size:size)
    ids=GameRoomTournaments::MatchOrder.players(input['matches'],selected,key:'unit_ids')
    raise GameRoomTournaments::Publication::Invalid,:invalid_membership unless ids.size==2 && ids.uniq.size==2
    sides=ids.map{|id|membership['units'].find{|unit|unit['unit_id']==id}}
    raise GameRoomTournaments::Publication::Invalid,:invalid_membership if sides.any?(&:nil?)
    unless selected['players'].sort==sides.flat_map{|unit|unit['accounts']}.sort
      raise GameRoomTournaments::Publication::Invalid,:invalid_membership
    end
    people=template.each_with_index.map do |side,index|
      account=sides[side]['accounts'][template.take(index).count(side)]
      {'account'=>account,'username'=>account,'seat'=>index,'team'=>sides[side]['unit_id']}
    end
    game=registry.build(input.fetch('game_id'))
    native=seats.native(game:game,options:input['game_options'],people:people,template:template,unit_size:size)
    data.freeze_tree({'players'=>people,'options'=>native})
  end
end
