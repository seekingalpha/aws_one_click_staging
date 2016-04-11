require 'aws_one_click_staging/bucket_sync_service'
require "aws_one_click_staging/aws_warrior"
require "aws_one_click_staging/version"

SOURCE_ROOT = File.expand_path("#{File.dirname(__FILE__)}/..")

module AwsOneClickStaging

  def self.stage(file=nil)
    warrior = AwsWarrior.new(file: file)
    return if warrior.nil?
    puts "cloning database from amazon... this takes a while..."
    warrior.clone_rds
    puts "cloning s3 bucket from amazon... this takes forever..."
    warrior.clone_s3_bucket

    puts warrior.get_fancy_string_of_staging_db_uri

    puts "\nOperations completed successfully!"
  end

  def self.check(file=nil)
    warrior = AwsWarrior.new(file: file) # this makes a config file if needed
    puts "This command *would* test that you have the needed permissions on the "
    puts "buckets and rds instances you named in your config file... "
    puts "but alas, you're reading the outputs of a stubbed method..."
  rescue => e
    puts e
  end

  def self.just_s3(file=nil)
    warrior = AwsWarrior.new(file: file)
    return if warrior.nil?

    puts "cloning s3 bucket from amazon... this takes forever..."
    warrior.clone_s3_bucket
    puts "\nOperations completed successfully!"

  end

  def self.just_rds(file=nil)
    warrior = AwsWarrior.new(file: file)
    return if warrior.nil?

    puts "cloning database from amazon... this takes a while..."
    warrior.clone_rds

    puts warrior.get_fancy_string_of_staging_db_uri

    puts "\nOperations completed successfully!"
  end

  def self.just_ec2(file=nil)
    warrior = AwsWarrior.new(file: file)
    puts "this is a stub because we only did this one time and don't feel need to repeat."
  end

end
