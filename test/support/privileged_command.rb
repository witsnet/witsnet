require "open3"

module PrivilegedCommand
  class Error < StandardError; end

  SANITIZED_ENV = {
    "RUBYOPT" => nil,
    "WITSNET_COVERAGE" => nil,
    "WITSNET_PROJECT_ROOT" => nil
  }.freeze
  PROPAGATED_ENV_KEYS = %w[
    RUBYOPT
    WITSNET_COVERAGE
    WITSNET_PROJECT_ROOT
  ].freeze

  module_function

  def capture3(*command)
    Open3.capture3(SANITIZED_ENV, *prefix, *command)
  rescue Errno::ENOENT => e
    raise Error, "Unable to run privileged command #{command.first.inspect}: #{e.message}"
  end

  def spawn(*command, **options)
    Process.spawn(SANITIZED_ENV, *prefix, *command, **options)
  rescue Errno::ENOENT => e
    raise Error, "Unable to run privileged command #{command.first.inspect}: #{e.message}"
  end

  def prefix
    return [] if Process.uid.zero?

    command = ENV.fetch("WITSNET_TEST_SUDO", "sudo -n").split
    raise Error, "WITSNET_TEST_SUDO is empty" if command.empty?

    command + ["env", *propagated_env_assignments]
  end

  def propagated_env_assignments
    PROPAGATED_ENV_KEYS.filter_map do |key|
      value = ENV[key]
      "#{key}=#{value}" if value
    end
  end
end
