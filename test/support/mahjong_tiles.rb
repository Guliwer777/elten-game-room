module MahjongTestTiles
  def mahjong_kinds(text)
    groups = text.scan(/([1-9]+)([mpsz])/)
    raise 'Invalid test hand notation' unless groups.map { |digits, suit| digits + suit }.join == text
    groups.flat_map do |digits, suit|
      base = {'m'=>0, 'p'=>9, 's'=>18, 'z'=>27}.fetch(suit)
      digits.chars.map do |digit|
        rank = Integer(digit)
        raise 'Invalid honor in test notation' if suit == 'z' && rank > 7
        base + rank - 1
      end
    end
  end
end
