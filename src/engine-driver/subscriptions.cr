require "logger"
require "redis"
require "retriable/core_ext/kernel"

# TODO:: we need to be scheduling these onto the correct thread
class ACAEngine::Driver::Subscriptions
  SYSTEM_ORDER_UPDATE = "lookup-change"

  def initialize(logger_io = STDOUT, module_id = "")
    @terminated = false
    @logger = ::Logger.new(logger_io)
    @logger.progname = module_id
    @logger.formatter = Logger::Formatter.new do |severity, datetime, progname, message, io|
      label = severity.unknown? ? "ANY" : severity.to_s
      io << String.build do |str|
        str << "level=" << label << " time="
        datetime.to_rfc3339(str)
        str << " progname=" << progname if progname && !progname.empty?
        str << " message=" << message
      end
    end

    # Mutex for indirect subscriptions as it involves two hashes, a redis lookup
    # and the possibility of an index change. The redis lookup pauses the
    # current fibre allowing for a race condition without a lock in place
    @mutex = Mutex.new

    # Channel name to subscriptions
    @subscriptions = {} of String => Array(ACAEngine::Driver::Subscriptions::Subscription)

    # System ID to subscriptions
    @redirections = {} of String => Array(ACAEngine::Driver::Subscriptions::IndirectSubscription)

    # Subscriptions need their own seperate client
    @redis_subscribe = new_redis_client

    # Is the subscription loop running?
    @running = false

    channel = Channel(Nil).new
    spawn(same_thread: true) { monitor_changes(channel) }
    channel.receive?
  end

  protected def new_redis_client
    Redis.new(url: ENV["REDIS_URL"]?)
  end

  @redis_subscribe : Redis
  getter :running, :logger

  def terminate(terminate = true) : Nil
    @terminated = terminate
    @running = false

    # Unsubscribe with no arguments unsubscribes from all, this will terminate
    # the subscription loop, allowing monitor_changes to return
    @redis_subscribe.unsubscribe([] of String)
  end

  # Self reference subscription
  def subscribe(module_id, status, &callback : (ACAEngine::Driver::Subscriptions::DirectSubscription, String) ->) : ACAEngine::Driver::Subscriptions::DirectSubscription
    sub = ACAEngine::Driver::Subscriptions::DirectSubscription.new(module_id.to_s, status.to_s, &callback)
    perform_subscribe(sub)
    sub
  end

  # Abstract subscription
  def subscribe(system_id, module_name, index, status, &callback : (ACAEngine::Driver::Subscriptions::IndirectSubscription, String) ->) : ACAEngine::Driver::Subscriptions::IndirectSubscription
    sub = ACAEngine::Driver::Subscriptions::IndirectSubscription.new(system_id.to_s, module_name.to_s, index.to_i, status.to_s, &callback)

    @mutex.synchronize {
      # Track indirect subscriptions
      subscriptions = @redirections[system_id] ||= [] of ACAEngine::Driver::Subscriptions::IndirectSubscription
      subscriptions << sub
      perform_subscribe(sub)
    }

    sub
  end

  # Provide generic channels for modules to communicate over
  def channel(name, &callback : (ACAEngine::Driver::Subscriptions::ChannelSubscription, String) -> Nil) : ACAEngine::Driver::Subscriptions::ChannelSubscription
    sub = ACAEngine::Driver::Subscriptions::ChannelSubscription.new(name.to_s, &callback)
    if channel = sub.subscribe_to
      # update the subscription cache
      if subscriptions = @subscriptions[channel]?
        subscriptions << sub
      else
        subscriptions = @subscriptions[channel] = [] of ACAEngine::Driver::Subscriptions::Subscription
        subscriptions << sub
        @redis_subscribe.subscribe [channel]
      end
    end
    sub
  end

  def unsubscribe(subscription : ACAEngine::Driver::Subscriptions::Subscription) : Nil
    @mutex.synchronize {
      # clean up indirect subscription (if this is one)
      if redirect = @redirections[subscription.system_id]?
        sub = redirect.delete(subscription)
        if sub == subscription && redirect.empty?
          @redirections.delete(subscription.system_id)
        end
      end

      # clean up subscription tracker
      channel = subscription.subscribe_to
      perform_unsubscribe(subscription, channel) if channel
    }
  end

  private def on_message(channel, message)
    if channel == SYSTEM_ORDER_UPDATE
      @mutex.synchronize { remap_indirect(message) }
    elsif subscriptions = @subscriptions[channel]?
      subscriptions.each do |subscription|
        subscription.callback @logger, message
      end
    else
      # subscribed to channel but no subscriptions
      @logger.warn "received message for channel with no subscription!\nChannel: #{channel}\nMessage: #{message}"
    end
  end

  private def monitor_changes(wait)
    wait.close

    retry max_interval: 5.seconds do
      begin
        wait = Channel(Nil).new

        # This will run on redis reconnect
        # We can't have this run in the subscribe block as the subscribe block
        # needs to return before we subscribe to further channels
        spawn(same_thread: true) {
          wait.receive?
          @mutex.synchronize {
            # re-subscribe to existing subscriptions here
            # NOTE:: sending an empty array errors
            @redis_subscribe.subscribe(@subscriptions.keys) if @subscriptions.size > 0

            # re-check indirect subscriptions
            @redirections.each_key do |system_id|
              remap_indirect(system_id)
            end

            @running = true

            # TODO:: check for any value changes
            # disconnect might have been a network partition and an update may
            # have occurred during this time gap
          }
        }

        # NOTE:: The crystal redis subscription API could use a little work.
        # The reason for all the sync and spawns is that the first subscribe
        # requires a block and subsequent ones throw an error with a block.
        # NOTE:: this version of subscribe only supports splat arguments
        @redis_subscribe.subscribe(SYSTEM_ORDER_UPDATE) do |on|
          on.message { |c, m| on_message(c, m) }
          spawn(same_thread: true) { wait.close }
        end

        raise "no subscriptions, restarting loop" unless @terminated
      rescue e
        @logger.warn "redis subscription loop exited\n#{e.message}\n#{e.backtrace?.try &.join("\n")}"
        raise e
      ensure
        wait.close
        @running = false

        # We need to re-create the subscribe object for our sanity
        @redis_subscribe = new_redis_client unless @terminated
      end
    end
  end

  private def remap_indirect(system_id)
    if subscriptions = @redirections[system_id]?
      subscriptions.each do |sub|
        subscribed = false

        # Check if currently mapped
        if sub.module_id
          current_channel = sub.subscribe_to
          sub.reset
          new_channel = sub.subscribe_to

          # Unsubscribe if channel changed
          if current_channel && current_channel != new_channel
            perform_unsubscribe(sub, current_channel)
          else
            subscribed = true
          end
        end

        perform_subscribe(sub) if !subscribed
      end
    end
  end

  private def perform_subscribe(subscription)
    if channel = subscription.subscribe_to
      # update the subscription cache
      if subscriptions = @subscriptions[channel]?
        subscriptions << subscription
      else
        subscriptions = @subscriptions[channel] = [] of ACAEngine::Driver::Subscriptions::Subscription
        subscriptions << subscription
        @redis_subscribe.subscribe [channel]
      end

      # notify of current value
      if current_value = subscription.current_value
        spawn(same_thread: true) { subscription.callback(@logger, current_value.not_nil!) }
      end
    end
  end

  private def perform_unsubscribe(subscription : ACAEngine::Driver::Subscriptions::Subscription, channel : String)
    if subscriptions = @subscriptions[channel]?
      sub = subscriptions.delete(subscription)
      if sub == subscription && subscriptions.empty?
        @subscriptions.delete(channel)
        @redis_subscribe.unsubscribe [channel]
      end
    end
  end
end

require "./subscriptions/*"
