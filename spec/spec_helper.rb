if ENV["CODECLIMATE_REPO_TOKEN"]
  require "simplecov"
  SimpleCov.start
end

require "interactor"
require "byebug"

Dir[File.expand_path("../support/*.rb", __FILE__)].sort.each { |f| require f }
