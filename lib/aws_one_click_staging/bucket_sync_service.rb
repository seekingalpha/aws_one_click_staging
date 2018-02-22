# props to bantic
# https://gist.github.com/bantic/4080793
require 'aws-sdk'
require "thwait"

class BucketSyncService
  attr_reader :from_bucket, :to_bucket, :logger
  attr_accessor :debug

  # DEFAULT_ACL = :public_read
  # PRIVATE_ACL = :private



  # credentials are the TO bucket's credentials, which have to
  # have at least READ access on the FROM bucket
  # prefix is a path filter for the FROM bucket
  def initialize(from_bucket, to_bucket, credentials, prefix)
    @from_bucket = bucket_from_credentials(from_bucket, credentials)
    @to_bucket   = bucket_from_credentials(to_bucket, credentials)
    @prefix      = prefix
  end

  def perform(output=STDOUT)
    Aws.eager_autoload! # this makes threads even more happy

    object_counts = {sync:0, skip:0}
    create_logger(output)

    threads = []

    logger.info "Starting sync."
    from_bucket.objects(prefix: @prefix).each do |object|
      threads << Thread.new {
        if object_needs_syncing?(object)
          sync(object)
          object_counts[:sync] += 1
        else
          logger.debug "Skipped #{pp object}"
          object_counts[:skip] += 1
        end
      }
      sleep 0.01 while threads.select {|t| t.alive?}.count > 16 # throttling
    end


    ThreadsWait.all_waits(threads)

    logger.info "Done. Synced #{object_counts[:sync]}, " +
      "skipped #{object_counts[:skip]}."
  end

  private

  def create_logger(output)
    @logger = Logger.new(output).tap do |l|
      l.level = debug ? Logger::DEBUG : Logger::INFO
    end
  end

  def sync(object)
    logger.debug "Syncing #{pp object}"
    acl_setting = file_is_public?(object) ? 'public-read' : 'private'
    to_object = to_bucket.object(object.key)
    to_object.copy_from(object, acl: acl_setting)
  end

  # Crude, but ala aws I think :)
  def file_is_public?(object)
    grants = object.acl.grants
    grants.each do |g|
      return true if g.permission == 'READ' && g.grantee.uri == "http://acs.amazonaws.com/groups/global/AllUsers"
    end
    return false
  end

  def pp(object)
    content_length_in_kb = object.content_length / 1024
    "#{object.key} #{content_length_in_kb}k " +
      "#{object.last_modified.strftime("%b %d %Y %H:%M")}"
  end

  def object_needs_syncing?(object)
    to_object = to_bucket.object(object.key)
    return true if !to_object.exists? # object isn't even present in the dst bucket

    return to_object.etag != object.etag # does the etag on the dst object differ from src?
  end


  def bucket_from_credentials(bucket, credentials)
    s3 = Aws::S3::Resource.new(credentials)

    bucket = s3.bucket(bucket)
    if !bucket.exists?
      bucket = s3.create_bucket(bucket)
    end
    bucket
  end
end




=begin
Example usage:
 credentials = {aws_access_key_id:"XXX", aws_secret_access_key:"YYY"}
 syncer = BucketSyncService.new("first-bucket", "second-bucket", credentials)
 syncer.debug = true # log each object
 syncer.perform
=end
