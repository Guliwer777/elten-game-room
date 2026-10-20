# encoding: UTF-8

module KrowaSjpHtml
  # Reduced SJP markup with invented meanings. Empty entries retain the
  # separator paragraph so it cannot accidentally become a definition.
  def self.entry(lemma, forms, meaning)
    rows = forms.map { |flag, words| "<tr><th><tt>#{flag}</tt></th><td>#{words.join(', ')}</td></tr>" }.join
    html = "<h1>Wynik</h1><div><table class='wtab' summary='wynik'>" \
      "<tr><th colspan='2'><b>#{lemma}</b></th></tr>" \
      "<tr><th>odmienność</th><td>#{forms.empty? ? 'nie' : 'tak'}</td></tr>#{rows}</table>" \
      "<p><b>znaczenie:</b> <span><a href='/info'>info</a></span></p></div>"
    html + (meaning ? "<p>#{meaning}</p>" : '') + '<p style="line-height: 1;">-</p>'
  end
end
