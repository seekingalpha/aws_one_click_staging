require 'fileutils'
require 'yaml'

module AwsOneClickStaging

  class ConfigFile
    class NewFileError < RuntimeError
    end

    def self.load(file=nil)
      file ||= default_file
      return nil if create_if_needed!(file)
      YAML.load_file(file)
    end

    def self.create_if_needed!(file)
      return false if File.exists?(file)

      puts "Config file not found, creating...\n\n"
      create!(file)

      msg = ""
      msg += "An empty config file was created for you in #{file}\n"
      msg += "Please populate it with the correct information and run this \n"
      msg += "command again.\n"
      raise NewFileError, msg
    end

    def self.default_file
      dir = "#{ENV['HOME']}/.config"
      File.expand_path("#{dir}/aws_one_click_staging.yml")
    end

    # copy example config file to config file path
    def self.create!(file=default_file)
      FileUtils.mkdir_p File.dirname(file)
      FileUtils.cp("#{SOURCE_ROOT}/config/aws_one_click_staging.yml", file)
    end
  end
end
