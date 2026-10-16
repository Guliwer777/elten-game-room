require_relative '../../lib/tournaments/server_plan_document'
T = GameRoomTournaments::ServerPlanDocument
anchor = {'operation_key' => 'a' * 64, 'tournament_id' => 5,
  'publication_digest' => 'b' * 64, 'roster_generation' => 'c' * 64}
document = {'version' => 1, 'status' => 'candidate', 'matches' => Array.new(40) { |i| {'number' => i, 'players' => ['Żółw', 'Guliwer'], 'note' => 'ą' * 30} }}
parts = T.encode(document, anchor: anchor)
raise 'Not multipart' unless parts.size > 2 && parts.all? { |row| row['payload'].bytesize <= 2048 }
rows = parts.each_with_index.map { |row, i| row.merge('__id' => i + 1, '__insertion_user' => 'guliwer') }
read = ->(values) { T.decode(values, anchor: anchor, author: 'Guliwer') }
raise 'Roundtrip' unless read.call(rows.reverse) == document && read.call(rows).frozen?
reject = ->(values) do
  begin
    read.call(values)
  rescue GameRoomTournaments::Publication::Invalid
    next
  end
  raise 'Invalid document accepted'
end
reject.call(rows.drop(1))
reject.call(rows[0...-1])
reject.call(rows + [rows.last])
retry_row = rows.last.merge('__id' => rows.size + 1)
raise 'Identical retried part rejected' unless read.call(rows + [retry_row]) == document
raise 'Canonical evidence changed' unless T.canonical_rows(rows + [retry_row], anchor: anchor, author: 'guliwer') == rows
reject.call(rows + [retry_row.merge('payload' => 'conflicting')])
reject.call(rows.map.with_index { |r, i| i == 1 ? r.merge('__insertion_user' => 'other') : r })
reject.call(rows.map.with_index { |r, i| i == 1 ? r.merge('tournament_id' => 6) : r })
reject.call(rows.map.with_index { |r, i| i == 1 ? r.merge('payload' => '!!!!') : r })
reject.call(rows.map.with_index { |r, i| i == 1 ? r.merge('payload' => Base64.strict_encode64('x' * 1536)) : r })
reject.call(rows.map.with_index { |r, i| i == 1 ? r.merge('document_digest' => 'd' * 64) : r })
malformed = '{"same":1,"same":2}'
common = anchor.merge('part_count' => 1, 'document_digest' => Digest::SHA256.hexdigest(malformed), '__insertion_user' => 'guliwer')
reject.call([common.merge('__id' => 1, 'part_index' => 0, 'payload' => ''),
  common.merge('__id' => 2, 'part_index' => 1, 'payload' => Base64.strict_encode64(malformed))])
puts 'PASS shared candidate document: bounded Unicode parts, order-independent complete read, author/scope/digest and duplicate JSON rejection'
