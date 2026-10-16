require_relative 'host_source'
path=File.join(EltenTestHost.root,'src/eapi/program.rb')
lines=File.readlines(path)
first=lines.index{|line|line.start_with?('  class NotificationPresentation')}
last=lines.index{|line|line.start_with?('  class Leaderboard')}
raise 'Native notification model boundaries missing' unless first && last
Object.class_eval("module Programs\n#{lines[first...last].join}\nend",path)
%w[app_notification_from notification_value map_app_notification receive_app_notification].each do |name|
  first=lines.index{|line|line.start_with?("    def #{name}(")}
  last=((first+1)...lines.size).find{|i|lines[i].start_with?('    def ')}
  raise 'Native notification dispatch boundary missing' unless first && last
  Object.class_eval("module Programs\nclass << self\n#{lines[first...last].join}\nend\nend",path)
end
