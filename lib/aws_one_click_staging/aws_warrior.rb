require "aws_one_click_staging/config_file"
require 'aws-sdk-rds'

module AwsOneClickStaging

  class AwsWarrior
    CREDENTIAL_KEYS = ["aws_region", "aws_access_key_id", "aws_secret_access_key"]

    class BadConfiguration < RuntimeError
    end

    attr_accessor :encrypted_snapshot

    def initialize file: nil, config: nil
      if config
        @config = config
        puts "initialize @config = config"
      else
        @config = ConfigFile.load(file)
        puts "initialize else @config = config"
      end
      puts "yo"
      puts @config
      setup_aws_credentials_and_configs
    end

    ## reuse_since: don't recreate snapshots if their newer than this
    def clone_rds(reuse_since: nil)
      new_snapshot = recreate_snapshot(reuse_since: reuse_since)
      clone_encrypted_snapshot(reuse_since: new_snapshot ? nil : reuse_since)
      recreate_staging_db_instance
    end

    def recreate_snapshot(reuse_since: nil)
      puts "recreate_snapshot"
      if reuse_since
        puts "recreate_snapshot reuse_since"
        snapshot_state = get_fresh_db_snapshot_state rescue nil
        puts snapshot_state
        if snapshot_state && snapshot_state.snapshot_create_time >= reuse_since
          puts "use existing encrypted snapshot"
          @encrypted_snapshot = snapshot_state.encrypted
          puts @encrypted_snapshot
          return
        end
      end

      delete_snapshot_for_staging!
      create_new_snapshot_for_staging!
      true
    end

    def clone_encrypted_snapshot(reuse_since: nil)
      puts "clone_encrypted_snapshot"
      return unless @config['production'] && @encrypted_snapshot
      return unless @config['production'] && encrypted_snapshot

      if reuse_since
        snapshot_state = get_fresh_db_encrypted_snapshot_copy_state rescue nil
        return if snapshot_state && snapshot_state.snapshot_create_time >= reuse_since
      end

      delete_encrypted_copy!
      create_encrypted_snapshot_copy!
#      delete_snapshot_for_staging!
      true
    end

    def recreate_staging_db_instance
      delete_staging_db_instance!
      spawn_new_staging_db_instance!
    end

    def clone_s3_bucket
      bs = BucketSyncService.new(@aws_production_bucket, @aws_staging_bucket,
                                 @staging_creds, @config['bucket_prefix'])
      bs.debug = true

      puts "beginning clone of S3 bucket, this can go on for tens of minutes..."
      bs.perform
    end

    def get_fancy_string_of_staging_db_uri
      get_fresh_db_instance_state(@db_instance_id_staging).endpoint.address
    end

    private

    def setup_aws_credentials_and_configs
      puts "setup_aws_credentials_and_configs"
      puts "@staging_creds:"
      puts @staging_creds
      if @staging_creds.nil?
        @staging_creds = setup_aws_credentials(@config['staging'] || @config)
        puts "@staging_creds:"
        puts @staging_creds
        Aws.config.update @staging_creds
      end
      @c_staging = Aws::RDS::Client.new
      if @config['production']
        @production_creds = setup_aws_credentials(@config['production'])
        @c_production = Aws::RDS::Client.new(@production_creds)
        puts "setup_aws_credentials_and_configs production"
        puts "@production_creds:"
        puts @production_creds
      else
        @production_creds = @staging_creds
        @c_production = @c_staging
        puts "setup_aws_credentials_and_configs else production"
        puts "@staging_creds and @staging_creds:"
        puts @production_creds
      end

      @aws_production_bucket = @config["aws_production_bucket"]
      @aws_staging_bucket = @config["aws_staging_bucket"]

      @db_instance_id_production = @config["db_instance_id_production"]
      @db_instance_id_staging = @config["db_instance_id_staging"]
      @db_snapshot_id = @config["db_snapshot_id"]
    end

    def setup_aws_credentials config
      puts "setup_aws_credentials"
      puts "config:"
      puts config
      cred_hash = {}
      aws_region = config["aws_region"]

      missing = CREDENTIAL_KEYS.select do |key|
        !config[key]
      end

      #check if there are some credentials on the machine
      begin
        identity = Aws::STS::Client.new().get_caller_identity
      rescue => e
        p "no credentials"
      else
        p "the credentials are:"
        p identity
      end

      if missing.none?
        puts "setup_aws_credentials missing.none?"
        access_key_id = config["aws_access_key_id"]
        secret_access_key = config["aws_secret_access_key"]
        cred_hash.update(credentials: Aws::Credentials.new(access_key_id, secret_access_key))
      end
      if missing.any? && `ec2metadata 2>/dev/null`.empty? && identity.nil?
        puts "setup_aws_credentials missing.any?"
        raise BadConfiguration, "The following required keys are missing: #{missing.join(', ')}"
      end
      if !config["aws_region"] && !`ec2metadata 2>/dev/null`.empty?
        aws_region = `ec2metadata --availability-zone`.chomp[0..-2]
        puts "setup_aws_credentials !config region && !ec2metadata"
      end
      cred_hash.update(region: aws_region)

      if config['role_arn']
        puts "setup_aws_credentials role_arn"
        sts = Aws::STS::Client.new(credentials: Aws::RDS::Client.new(cred_hash).config.credentials, region: aws_region)
        cred_hash = {
          credentials: Aws::AssumeRoleCredentials.new(
            client: sts,
            role_arn: config['role_arn'],
            role_session_name: 'warrior-on-production'
          ),
          region: aws_region,
        }
      end
      puts "setup_aws_credentials cred_hash:"
      puts cred_hash
      cred_hash
    end

    def delete_snapshot_for_staging!
      puts "deleting staging db snapshot"
      response = @c_production.delete_db_snapshot(db_snapshot_identifier: @db_snapshot_id)

      sleep 1 while response.db_snapshot.percent_progress != 100
      true
    rescue
      false
    end

    def delete_encrypted_copy!
      puts "deleting old copy of encrypted staging db snapshot"
      response = @c_staging.delete_db_snapshot(db_snapshot_identifier: @db_snapshot_id)

      sleep 1 while response.db_snapshot.percent_progress != 100
      true
    rescue
      false
    end

    def create_new_snapshot_for_staging!
      puts "creating new snapshot..."
      details = @c_production.create_db_snapshot({db_instance_identifier: @db_instance_id_production,
        db_snapshot_identifier: @db_snapshot_id })
      @encrypted_snapshot = details.db_snapshot.encrypted

      sleep 10 while get_fresh_db_snapshot_state.status != "available"

      if @config["production"]
        @c_production.modify_db_snapshot_attribute(
          db_snapshot_identifier: @db_snapshot_id,
          attribute_name: 'restore',
          values_to_add: [Aws::STS::Client.new(@staging_creds).get_caller_identity.account]
        )
      end
    end

    def create_encrypted_snapshot_copy!
      puts 'copying shared encrypted snapshot...'
      puts @c_staging
      puts "arn:aws:rds:#{Aws.config[:region]}:#{@config['production']['account_id']}:snapshot:#{@db_snapshot_id}"
      puts @db_snapshot_id
      puts @config['kms_key_id']

      begin
        identity = Aws::STS::Client.new().get_caller_identity
      rescue => e
        p "no credentials"
      else
        p "the credentials are:"
        p identity
      end

      @c_staging.copy_db_snapshot(
        source_db_snapshot_identifier: "arn:aws:rds:#{Aws.config[:region]}:#{@config['production']['account_id']}:snapshot:#{@db_snapshot_id}",
        target_db_snapshot_identifier: @db_snapshot_id,
        kms_key_id: @config['kms_key_id'],
      )

      sleep 10 while get_fresh_db_encrypted_snapshot_copy_state.status != "available"
    end

    def delete_staging_db_instance!
      puts "Deleting old staging instance..."
      @c_staging.delete_db_instance(db_instance_identifier: @db_instance_id_staging,
        skip_final_snapshot: true)

      sleep 10 until db_instance_is_deleted?(@db_instance_id_staging)
    rescue
      false
    end

    def spawn_new_staging_db_instance!
      puts "Spawning a new fully clony RDS db instance for staging purposes"

      db_snapshot_id = if @config["production"] && !encrypted_snapshot
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
      instance_state.db_instance_status == 'available' &&
        instance_state.pending_modified_values.values.flatten(1).compact.empty?
    end

    def get_fresh_db_snapshot_state
      @c_production.describe_db_snapshots(db_snapshot_identifier: @db_snapshot_id).db_snapshots.first
    end

    def get_fresh_db_encrypted_snapshot_copy_state
      @c_staging.describe_db_snapshots(db_snapshot_identifier: @db_snapshot_id).db_snapshots.first
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
