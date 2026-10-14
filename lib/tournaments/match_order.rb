module GameRoomTournaments
  # Keep immutable match identities; derive return seats from the first leg.
  module MatchOrder
    def self.players(matches, match, key: 'players')
      return match.fetch(key) unless match['leg'] == 2
      first = matches.find { |row| row['leg'] == 1 && row.fetch(key).sort == match.fetch(key).sort }
      (first || match).fetch(key).reverse
    end
  end
end
