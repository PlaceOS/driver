require "deque"
require "json"

abstract class PlaceOS::Driver
  # a device or service that provides sensor data, either singular or for multiple devices
  module Presence::Smoother
    record Transition,
      at : Time::Instant,
      state : Bool

    record Snapshot,
      # Smoothed/latched output state.
      state : Bool,

      # Whether the smoothed state changed during this poll.
      changed : Bool,

      # Most recently observed raw sensor state.
      raw_state : Bool,

      # Confidence in the smoothed output state, from 0.0 to 1.0.
      confidence : Float64,

      # Percentage equivalent of confidence, from 0.0 to 100.0.
      confidence_percent : Float64,

      # Proportion of the evaluated period attributed to each raw state.
      on_fraction : Float64,
      off_fraction : Float64,

      # Amount of history currently available.
      observed_for : Time::Span,

      # True once at least one complete smoothing window exists.
      window_ready : Bool

    getter output_state : Bool?
    getter raw_state : Bool?

    @transitions = Deque(Transition).new
    @first_seen_at : Time::Instant? = nil
    @mutex = Mutex.new

    def initialize(
      @window : Time::Span = 3.minutes,
      @threshold : Float64 = 0.70,
    )
      unless @window > 0.seconds
        raise ArgumentError.new("window must be greater than zero")
      end

      unless @threshold > 0.5 && @threshold <= 1.0
        raise ArgumentError.new(
          "threshold must be greater than 0.5 and no greater than 1.0"
        )
      end
    end

    # Records a raw sensor state.
    #
    # The first observation establishes the initial smoothed output state.
    # Repeated observations of the same state are ignored because the state
    # continues accumulating time without requiring another transition.
    def observe(
      state : Bool,
      at : Time::Instant = Time.instant,
    ) : Nil
      @mutex.synchronize do
        unless @transitions.empty?
          if at < @transitions.last.at
            raise ArgumentError.new(
              "observation timestamps must be monotonically increasing"
            )
          end
        end

        if @raw_state.nil?
          @raw_state = state
          @output_state = state
          @first_seen_at = at
          @transitions << Transition.new(at, state)
          return
        end

        # No transition occurred.
        return if @raw_state == state

        @raw_state = state
        @transitions << Transition.new(at, state)
      end
    end

    # Evaluates the current sliding window and returns the smoothed state,
    # confidence and supporting information.
    #
    # Returns nil until the first sensor observation.
    def poll(
      now : Time::Instant = Time.instant,
    ) : Snapshot?
      @mutex.synchronize do
        raw_state = @raw_state
        output_state = @output_state
        first_seen_at = @first_seen_at

        return nil if raw_state.nil?
        return nil if output_state.nil?
        return nil if first_seen_at.nil?

        if now < first_seen_at
          raise ArgumentError.new(
            "poll timestamp precedes the first observation"
          )
        end

        unless @transitions.empty?
          if now < @transitions.last.at
            raise ArgumentError.new(
              "poll timestamp precedes the latest observation"
            )
          end
        end

        on_fraction, off_fraction, evaluated_for =
          calculate_fractions(now, first_seen_at)

        window_ready = now - first_seen_at >= @window
        changed = false

        # The initial output remains latched until a full window exists.
        if window_ready
          if output_state
            # Currently on: require enough off time to switch off.
            if off_fraction >= @threshold
              output_state = false
              changed = true
            end
          else
            # Currently off: require enough on time to switch on.
            if on_fraction >= @threshold
              output_state = true
              changed = true
            end
          end
        end

        @output_state = output_state

        confidence =
          if output_state
            on_fraction
          else
            off_fraction
          end

        Snapshot.new(
          state: output_state,
          changed: changed,
          raw_state: raw_state,
          confidence: confidence,
          confidence_percent: confidence * 100.0,
          on_fraction: on_fraction,
          off_fraction: off_fraction,
          observed_for: evaluated_for,
          window_ready: window_ready
        )
      end
    end

    # Returns confidence in the current smoothed output state, from 0.0 to 1.0.
    #
    # Calling this also evaluates whether the smoothed state should change.
    def confidence(
      now : Time::Instant = Time.instant,
    ) : Float64?
      poll(now).try(&.confidence)
    end

    # Returns confidence in the current smoothed output state as a percentage.
    #
    # For example, 56.3 means 56.3% confidence.
    def confidence_percent(
      now : Time::Instant = Time.instant,
    ) : Float64?
      poll(now).try(&.confidence_percent)
    end

    private def calculate_fractions(
      now : Time::Instant,
      first_seen_at : Time::Instant,
    ) : Tuple(Float64, Float64, Time::Span)
      cutoff = now - @window

      # Retain the most recent transition at or before the window boundary.
      # It tells us which state was active when the window began.
      while @transitions.size > 1 &&
            @transitions[1].at <= cutoff
        @transitions.shift
      end

      start_at =
        if first_seen_at > cutoff
          first_seen_at
        else
          cutoff
        end

      cursor = start_at
      segment_state = @transitions.first.state

      on_seconds = 0.0
      off_seconds = 0.0

      @transitions.each do |transition|
        # Find the state active at the beginning of the evaluated period.
        if transition.at <= start_at
          segment_state = transition.state
          next
        end

        break if transition.at > now

        duration = (transition.at - cursor).total_seconds

        if segment_state
          on_seconds += duration
        else
          off_seconds += duration
        end

        cursor = transition.at
        segment_state = transition.state
      end

      # Attribute time since the final transition to its active state.
      tail_duration = (now - cursor).total_seconds

      if segment_state
        on_seconds += tail_duration
      else
        off_seconds += tail_duration
      end

      total_seconds = on_seconds + off_seconds

      if total_seconds <= 0.0
        # At the exact instant of the first observation there has been no
        # measurable duration. Treat the initial state as fully confident.
        on_fraction = segment_state ? 1.0 : 0.0
        off_fraction = segment_state ? 0.0 : 1.0

        return {
          on_fraction,
          off_fraction,
          0.seconds,
        }
      end

      {
        on_seconds / total_seconds,
        off_seconds / total_seconds,
        now - start_at,
      }
    end
  end
end
