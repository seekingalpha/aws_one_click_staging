require 'spec_helper'

describe AwsOneClickStaging do

  before :each do
    @mocked_home = "/tmp/aws_one_click_staging_mock_home" # intentionally non-dry for feeling good about deleting it

    reset_test_env
  end

  it 'has a version number' do
    expect(AwsOneClickStaging::VERSION).not_to be nil
  end

  it 'can check config files' do
    expect{AwsOneClickStaging::AwsWarrior.new(file: "#{@mocked_home}/aws_one_click_staging.yml")}.to raise_error(AwsOneClickStaging::ConfigFile::NewFileError)

    expect(File.exists?("#{ENV['HOME']}/aws_one_click_staging.yml")).to be true

    expect{AwsOneClickStaging::AwsWarrior.new(file: "#{@mocked_home}/aws_one_click_staging.yml")}.to raise_error(AwsOneClickStaging::AwsWarrior::BadConfiguration)
  end


  describe 'AwsWarrior' do

    before :each do
      config = AwsOneClickStaging::ConfigFile.load
      # for testing without AWS accounts
      config.each_key {|key| config[key] = 'nonsense' if !config[key]}
      ['staging', 'production'].each do |scope|
        hash = config[scope].to_h
        hash.each_key {|key| hash[key] = 'nonsense' if !hash[key]}
      end
      @aws_warrior = AwsOneClickStaging::AwsWarrior.new(config: config)
    end

    it 'can clone an RDS database' do
      #@aws_warrior.clone_rds
    end

    it 'can clone a bitbucket' do
      #@aws_warrior.clone_s3_bucket
    end

    it 'can figure out an aws RDS URL' do
      #puts @aws_warrior.get_fancy_string_of_staging_db_uri
    end

    it 'has a test section for work benching' do
      # s3 = Aws::S3::Client.new
      # s3.get_object_acl(bucket: 'actioncenter', key: 'images/000/000/008/original/jeffflake.jpeg')
      # binding.pry
      # exit
      # o = s3.get_object(bucket: 'actioncenter', key: 'images/000/000/008/original/jeffflake.jpeg')
    end
  end

end
