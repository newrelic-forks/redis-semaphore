require 'redis'

class Redis
  class Semaphore
    EXISTS_TOKEN = "1"
    API_VERSION = "1"

    # stale_client_timeout is the threshold of time before we assume
    # that something has gone terribly wrong with a client and we
    # invalidate it's lock.
    # Default is nil for which we don't check for stale clients
    # Redis::Semaphore.new(:my_semaphore, :stale_client_timeout => 30, :redis => myRedis)
    # Redis::Semaphore.new(:my_semaphore, :redis => myRedis)
    # Redis::Semaphore.new(:my_semaphore, :resources => 1, :redis => myRedis)
    # Redis::Semaphore.new(:my_semaphore, :host => "", :port => "")
    # Redis::Semaphore.new(:my_semaphore, :path => "bla")
    def initialize(name, opts = {})
      @name = name
      @expiration = opts.delete(:expiration)
      @resource_count = opts.delete(:resources) || 1
      @stale_client_timeout = opts.delete(:stale_client_timeout)
      @redis = opts.delete(:redis) || Redis.new(opts)
      @use_local_time = opts.delete(:use_local_time)
      @tokens = []
    end

    def exists_or_create!
      token = @redis.getset(exists_key, EXISTS_TOKEN)

      if token.nil?
        create!
      else
        # Previous versions of redis-semaphore did not set `version_key`.
        # Make sure it's set now, so we can use it in future versions.

        if token == API_VERSION && @redis.get(version_key).nil?
          @redis.set(version_key, API_VERSION)
        end

        set_expiration_if_necessary
        true
      end
    end

    def available_count
      @redis.llen(available_key)
    end

    def delete!
      @redis.del(available_key)
      @redis.del(grabbed_key)
      @redis.del(exists_key)
      @redis.del(version_key)
    end

    def lock(timeout = 0)
      exists_or_create!
      release_stale_locks! if check_staleness?

      token_pair = @redis.blpop(available_key, timeout)
      return false if token_pair.nil?

      current_token = token_pair[1]
      @tokens.push(current_token)
      @redis.hset(grabbed_key, current_token, current_time.to_f)
      return_value = current_token

      if block_given?
        begin
          return_value = yield current_token
        ensure
          signal(current_token)
        end
      end

      return_value
    end
    alias_method :wait, :lock

    def unlock
      return false unless locked?
      signal(@tokens.pop)[1]
    end

    def locked?(token = nil)
      if token
        @redis.hexists(grabbed_key, token)
      else
        @tokens.each do |token|
          return true if locked?(token)
        end

        false
      end
    end

    def signal(token = 1)
      token ||= generate_unique_token

      @redis.multi do
        @redis.hdel grabbed_key, token
        @redis.lpush available_key, token
      end
    end

    def exists?
      @redis.exists(exists_key)
    end

    def all_tokens
      @redis.multi do
        @redis.lrange(available_key, 0, -1)
        @redis.hkeys(grabbed_key)
      end.flatten
    end

    def generate_unique_token
      tokens = all_tokens
      token = Random.rand.to_s

      while(tokens.include? token)
        token = Random.rand.to_s
      end
    end

    def release_stale_locks!
      simple_mutex(:release_locks, 10) do
        @redis.hgetall(grabbed_key).each do |token, locked_at|
          timed_out_at = locked_at.to_f + @stale_client_timeout

          if timed_out_at < current_time.to_f
            signal(token)
          end
        end
      end
    end

  private

    def simple_mutex(key_name, timeout = nil)
      mutex_key = namespaced_key(key_name) if key_name.kind_of? Symbol
      lock_timestamp = Time.now.to_i

      acquired = @redis.setnx(mutex_key, lock_timestamp)
      if !acquired
        locked_at = @redis.get(mutex_key).to_i
        return false if !lock_expired(locked_at, timeout)
        locked_at_2 = @redis.getset(mutex_key, Time.now.to_i).to_i
        return false if locked_at_2 != locked_at
      end

      begin
        yield
      ensure
        if !lock_expired(lock_timestamp, timeout)
          # There's still a tiny race condition here. Whee!
          @redis.del(mutex_key)
        end
      end
    end

    def lock_expired(timestamp, timeout)
      timestamp + timeout < Time.now.to_i
    end

    def create!
      @redis.expire(exists_key, 10)

      @redis.multi do
        @redis.del(grabbed_key)
        @redis.del(available_key)
        @resource_count.times do |index|
          @redis.rpush(available_key, index)
        end
        @redis.set(version_key, API_VERSION)
        @redis.persist(exists_key)

        set_expiration_if_necessary
      end
    end

    def set_expiration_if_necessary
      if @expiration
        [available_key, exists_key, version_key].each do |key|
          @redis.expire(key, @expiration)
        end
      end
    end

    def check_staleness?
      !@stale_client_timeout.nil?
    end

    def redis_namespace?
      (defined?(Redis::Namespace) && @redis.is_a?(Redis::Namespace))
    end

    def namespaced_key(variable)
      if redis_namespace?
        "#{@name}:#{variable}"
      else
        "SEMAPHORE:#{@name}:#{variable}"
      end
    end

    def available_key
      @available_key ||= namespaced_key('AVAILABLE')
    end

    def exists_key
      @exists_key ||= namespaced_key('EXISTS')
    end

    def grabbed_key
      @grabbed_key ||= namespaced_key('GRABBED')
    end

    def version_key
      @version_key ||= namespaced_key('VERSION')
    end

    def current_time
      if @use_local_time
        Time.now
      else
        begin
          instant = redis_namespace? ? @redis.redis.time : @redis.time
          Time.at(instant[0], instant[1])
        rescue
          @use_local_time = true
          current_time
        end
      end
    end
  end
end
