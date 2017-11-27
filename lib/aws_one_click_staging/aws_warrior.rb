require "aws_one_click_staging/config_file"
require 'aws-sdk'

module AwsOneClickStaging

  class AwsWarrior
    CREDENTIAL_KEYS = ["aws_region", "aws_access_key_id", "aws_secret_access_key"]

    class BadConfiguration < RuntimeError
    end

    def initialize file: nil, config: nil
      if config
        @config = config
      else
        @config = ConfigFile.load(file)
      end
      setup_aws_credentials_and_configs
    end

    def clone_rds
      delete_snapshot_for_staging!
      create_new_snapshot_for_staging!

      delete_staging_db_instance!
      spawn_new_staging_db_instance!
    end

    def clone_s3_bucket
      from_settings = { credentials: @production_creds,
        bucket: @aws_production_bucket}
      to_settings = { credentials: @staging_creds,
        bucket: @aws_staging_bucket}

      bs = BucketSyncService.new(from_settings, to_settings)
      bs.debug = true

      puts "beginning clone of S3 bucket, this can go on for tens of minutes..."
      bs.perform
    end

    def get_fancy_string_of_staging_db_uri
      get_fresh_db_instance_state(@db_instance_id_staging).endpoint.address
    end

    private

    def setup_aws_credentials_and_configs
      @staging_creds = setup_aws_credentials(@config['staging'] || @config)
      Aws.config.update @staging_creds
      @c_staging = Aws::RDS::Client.new
      if @config['production']
        @production_creds = setup_aws_credentials(@config['production'])
        @c_production = Aws::RDS::Client.new(@production_creds)
      else
        @production_creds = @staging_creds
        @c_production = @c_staging
      end

      @aws_production_bucket = @config["aws_production_bucket"]
      @aws_staging_bucket = @config["aws_staging_bucket"]

      @db_instance_id_production = @config["db_instance_id_production"]
      @db_instance_id_staging = @config["db_instance_id_staging"]
      @db_snapshot_id = @config["db_snapshot_id"]
    end

    def setup_aws_credentials config
      cred_hash = {}

      aws_region = config["aws_region"]

      missing = CREDENTIAL_KEYS.select do |key|
        !config[key]
      end
      if missing.none?
        access_key_id = config["aws_access_key_id"]
        secret_access_key = config["aws_secret_access_key"]
        cred_hash.update(credentials: Aws::Credentials.new(access_key_id, secret_access_key))
      end
      if missing.any? && `ec2metadata 2>/dev/null`.empty?
        raise BadConfiguration, "The following required keys are missing: #{missing.join(', ')}"
      end
      if !config["aws_region"] && !`ec2metadata 2>/dev/null`.empty?
        aws_region = `ec2metadata --availability-zone`.chomp[0..-2]
      end
      cred_hash.update(region: aws_region)

      if config['role_arn']
        sts = Aws::STS::Client.new(credentials: Aws::RDS::Client.new(cred_hash).config.credentials)
        cred_hash = {
          credentials: Aws::AssumeRoleCredentials.new(
            client: sts,
            role_arn: config['role_arn'],
            role_session_name: 'warrior-on-production'
          )
        }
      end

      cred_hash
    end

    def delete_snapshot_for_staging!
      puts "deleting old staging db snapshot"
      response = @c_production.delete_db_snapshot(db_snapshot_identifier: @db_snapshot_id)

      sleep 1 while response.db_snapshot.percent_progress != 100
      true
    rescue
      false
    end

    def create_new_snapshot_for_staging!
      puts "creating new snapshot..."
      @c_production.create_db_snapshot({db_instance_identifier: @db_instance_id_production,
        db_snapshot_identifier: @db_snapshot_id })

      sleep 10 while get_fresh_db_snapshot_state.status != "available"

      if @config["production"]
        @c_production.modify_db_snapshot_attribute(
          db_snapshot_identifier: @db_snapshot_id,
          attribute_name: 'restore',
          values_to_add: [Aws::STS::Client.new(@staging_creds).get_caller_identity.account]
        )
      end

      true
    rescue
      false
    end

    def delete_staging_db_instance!
      puts "Deleting old staging instance... This one's a doozy =/"
      @c_staging.delete_db_instance(db_instance_identifier: @db_instance_id_staging,
        skip_final_snapshot: true)

      sleep 10 until db_instance_is_deleted?(@db_instance_id_staging)
    rescue
      false
    end

    def spawn_new_staging_db_instance!
      puts "Spawning a new fully clony RDS db instance for staging purposes"

      db_snapshot_id = if @config["production"]
                         "arn:aws:rds:#{Aws.config[:region]}:#{@config["production"]["account_id"]}:snapshot:#{@db_snapshot_id}"
                       else
                         @db_snapshot_id
                       end
      options = @config['db_staging_options'].to_h.merge(
        db_instance_identifier: @db_instance_id_staging,
        db_snapshot_identifier: db_snapshot_id,
      )
      @c_staging.restore_db_instance_from_db_snapshot(options)

      sleep 10 while get_fresh_db_instance_state(@db_instance_id_staging).db_instance_status != "available"

      if @config['db_staging_modifications']
        modifications = @config['db_staging_modifications'].merge(
          db_instance_identifier: @db_instance_id_staging,
          apply_immediately: true # will happen during the next maintenance window otherwise
        )
        @c_staging.modify_db_instance(modifications)
        sleep 10 until db_instance_ready?(@db_instance_id_staging)
      end
    end

    def db_instance_ready?(db_instance_id)
      instance_state = get_fresh_db_instance_state(db_instance_id)
      instance_state.db_instance_status == "available" && instance_state.pending_modified_values.empty?
    end

    # we use this methods cause amazon lawl-pain
    def get_fresh_db_snapshot_state
      @c_production.describe_db_snapshots(db_snapshot_identifier: @db_snapshot_id).db_snapshots.first
    end

    def get_fresh_db_instance_state(db_instance_id)
      @c_staging.describe_db_instances(db_instance_identifier: db_instance_id).db_instances.first
    end

    def db_instance_is_deleted?(db_instance_id)
      get_fresh_db_instance_state(db_instance_id)
      false
    rescue Aws::RDS::Errors::DBInstanceNotFound
      true
    end
  end

end
