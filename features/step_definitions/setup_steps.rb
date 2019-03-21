Given('the following gitlab-ci config:') do |config|
  write_file('.gitlab-ci.yml', config)
end
