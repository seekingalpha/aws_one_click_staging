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
      from_settings = { credentials: Aws.config,
        bucket: @aws_production_bucket}
      to_settings = { credentials: Aws.config,
        bucket: @aws_staging_bucket}

      bs = BucketSyncService.new(from_settings, to_settings)
      bs.debug = true

      puts "beginning clone of S3 bucket, this can go on for tens of minutes..."
      bs.perform
    end

    def get_fancy_string_of_staging_db_uri
      l = 66
      msg = ""
      msg += "*" * l + "\n"
      msg += "* "
      msg += get_fresh_db_instance_state(@db_instance_id_staging).endpoint.address
      msg += "  *\n"
      msg += "*" * l
      msg
    end

    private

    def setup_aws_credentials_and_configs
      aws_region = @config["aws_region"]

      missing = CREDENTIAL_KEYS.select do |key|
        !@config[key]
      end
      if missing.none?
        access_key_id = @config["aws_access_key_id"]
        secret_access_key = @config["aws_secret_access_key"]
        Aws.config.update(credentials: Aws::Credentials.new(access_key_id, secret_access_key))
      end
      if missing.any? && `ec2metadata 2>/dev/null`.empty?
        raise BadConfiguration, "The following required keys are missing: #{missing.join(', ')}"
      end
      if !@config["aws_region"] && !`ec2metadata 2>/dev/null`.empty?
        aws_region = `ec2metadata --availability-zone`.chomp[0..-2]
      end
      Aws.config.update(region: aws_region)

      @master_user_password = @config["aws_master_user_password"]
      @aws_production_bucket = @config["aws_production_bucket"]
      @aws_staging_bucket = @config["aws_staging_bucket"]

      @db_instance_id_production = @config["db_instance_id_production"]
      @db_instance_id_staging = @config["db_instance_id_staging"]
      @db_snapshot_id = @config["db_snapshot_id"]


      @c = Aws::RDS::Client.new
    end

    def delete_snapshot_for_staging!
      puts "deleting old staging db snapshot"
      response = @c.delete_db_snapshot(db_snapshot_identifier: @db_snapshot_id)

      sleep 1 while response.db_snapshot.percent_progress != 100
      true
    rescue
      false
    end

    def create_new_snapshot_for_staging!
      puts "creating new snapshot... this takes like 170 seconds..."
      response = @c.create_db_snapshot({db_instance_identifier: @db_instance_id_production,
        db_snapshot_identifier: @db_snapshot_id })

      sleep 10 while get_fresh_db_snapshot_state.status != "available"
      true
    rescue
      false
    end


    def delete_staging_db_instance!
      puts "Deleting old staging instance... This one's a doozy =/"
      response = @c.delete_db_instance(db_instance_identifier: @db_instance_id_staging,
        skip_final_snapshot: true)

      sleep 10 until db_instance_is_deleted?(@db_instance_id_staging)
    rescue
      false
    end

    def spawn_new_staging_db_instance!
      puts "Spawning a new fully clony RDS db instance for staging purposes"

      @c.describe_db_snapshots(db_snapshot_identifier: @db_snapshot_id).db_snapshots.first

      response = @c.restore_db_instance_from_db_snapshot(
        db_instance_identifier: @db_instance_id_staging,
        db_snapshot_identifier: @db_snapshot_id,
        db_instance_class: "db.t1.micro"
      )


      sleep 10 while get_fresh_db_instance_state(@db_instance_id_staging).db_instance_status != "available"

      # sets password for staging db and disables automatic backups
      response = @c.modify_db_instance(
        db_instance_identifier: @db_instance_id_staging,
        backup_retention_period: 0,
        master_user_password: @master_user_password
      )
      sleep 2 while get_fresh_db_instance_state(@db_instance_id_staging).db_instance_status != "available"
    end


    # we use this methods cause amazon lawl-pain
    def get_fresh_db_snapshot_state
      @c.describe_db_snapshots(db_snapshot_identifier: @db_snapshot_id).db_snapshots.first
    end

    def get_fresh_db_instance_state(db_instance_id)
      @c.describe_db_instances(db_instance_identifier: db_instance_id).db_instances.first
    end

    def db_instance_is_deleted?(db_instance_id)
      @c.describe_db_instances(db_instance_identifier: db_instance_id).db_instances.first
      false
    rescue Aws::RDS::Errors::DBInstanceNotFound => e
      true
    end
  end

end
