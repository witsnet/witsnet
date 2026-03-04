require "rake/testtask"

desc "Run all tests under test/"
Rake::TestTask.new(:test) do |t|
  t.pattern = "test/**/*_test.rb"
end

task default: :test
