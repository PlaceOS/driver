require "../helper"
require "../../src/placeos-driver/interface/presence_smoother"

# Test harness: the smoother is a mix-in, so exercise it through a concrete
# class. Timestamps are `Time::Instant` values, which have no public
# constructor, so each spec captures a `base = Time.instant` and expresses
# every observation/poll time as `base + offset`. The offsets keep the specs
# deterministic (all arithmetic is relative) without sleeping.
private class TestSmoother
  include PlaceOS::Driver::Presence::Smoother
end

describe PlaceOS::Driver::Presence::Smoother do
  describe "initialization" do
    it "rejects a non-positive window" do
      expect_raises(ArgumentError, /window/) do
        TestSmoother.new(window: 0.seconds)
      end
      expect_raises(ArgumentError, /window/) do
        TestSmoother.new(window: -1.seconds)
      end
    end

    it "rejects a threshold outside (0.5, 1.0]" do
      expect_raises(ArgumentError, /threshold/) do
        TestSmoother.new(threshold: 0.5)
      end
      expect_raises(ArgumentError, /threshold/) do
        TestSmoother.new(threshold: 1.1)
      end
      # boundary values are accepted
      TestSmoother.new(threshold: 0.5001)
      TestSmoother.new(threshold: 1.0)
    end
  end

  describe "before any observation" do
    it "has no state" do
      smoother = TestSmoother.new
      smoother.output_state.should be_nil
      smoother.raw_state.should be_nil
    end

    it "returns nil from poll and the confidence helpers" do
      base = Time.instant
      smoother = TestSmoother.new(10.seconds)
      smoother.poll(base + 5.seconds).should be_nil
      smoother.confidence(base + 5.seconds).should be_nil
      smoother.confidence_percent(base + 5.seconds).should be_nil
    end
  end

  describe "the first observation" do
    it "establishes both the raw and smoothed state" do
      base = Time.instant
      smoother = TestSmoother.new(10.seconds)
      smoother.observe(true, at: base)

      smoother.raw_state.should eq(true)
      smoother.output_state.should eq(true)
    end

    it "reports full confidence at the exact instant it is seen" do
      base = Time.instant
      smoother = TestSmoother.new(10.seconds)
      smoother.observe(true, at: base)

      snapshot = smoother.poll(base).not_nil!
      snapshot.state.should eq(true)
      snapshot.raw_state.should eq(true)
      snapshot.changed.should eq(false)
      snapshot.confidence.should eq(1.0)
      snapshot.confidence_percent.should eq(100.0)
      snapshot.on_fraction.should eq(1.0)
      snapshot.off_fraction.should eq(0.0)
      snapshot.observed_for.should eq(0.seconds)
      snapshot.window_ready.should eq(false)
    end
  end

  describe "latching before a full window exists" do
    it "holds the initial state even when the raw sensor flips" do
      base = Time.instant
      smoother = TestSmoother.new(10.seconds, 0.7)
      smoother.observe(false, at: base)
      # sensor immediately reports presence, but the window is not yet full
      smoother.observe(true, at: base + 1.second)

      snapshot = smoother.poll(base + 5.seconds).not_nil!
      snapshot.window_ready.should eq(false)
      snapshot.raw_state.should eq(true) # raw follows the sensor
      snapshot.state.should eq(false)    # smoothed output stays latched
      snapshot.changed.should eq(false)
    end
  end

  describe "smoothing an unreliable sensor" do
    it "switches on when on-time dominates the window" do
      base = Time.instant
      smoother = TestSmoother.new(10.seconds, 0.7)
      smoother.observe(false, at: base)
      smoother.observe(true, at: base + 1.second)
      # a brief flicker off part way through the window
      smoother.observe(false, at: base + 5.seconds)
      smoother.observe(true, at: base + 6.seconds)

      snapshot = smoother.poll(base + 11.seconds).not_nil!
      snapshot.window_ready.should eq(true)
      snapshot.state.should eq(true)
      snapshot.changed.should eq(true)
      # 9s on / 1s off across the 10s window
      snapshot.on_fraction.should be_close(0.9, 1e-9)
      snapshot.off_fraction.should be_close(0.1, 1e-9)
      snapshot.confidence.should be_close(0.9, 1e-9)
    end

    it "switches off when off-time dominates the window" do
      base = Time.instant
      smoother = TestSmoother.new(10.seconds, 0.7)
      smoother.observe(true, at: base)
      smoother.observe(false, at: base + 1.second)

      snapshot = smoother.poll(base + 10.seconds).not_nil!
      snapshot.window_ready.should eq(true)
      snapshot.state.should eq(false)
      snapshot.changed.should eq(true)
      snapshot.off_fraction.should be_close(0.9, 1e-9)
      snapshot.confidence.should be_close(0.9, 1e-9)
    end

    it "rejects noise that stays below the threshold" do
      base = Time.instant
      smoother = TestSmoother.new(10.seconds, 0.7)
      smoother.observe(false, at: base)
      # 6s on / 4s off => on_fraction 0.6, below the 0.7 flip threshold
      smoother.observe(true, at: base + 4.seconds)

      snapshot = smoother.poll(base + 10.seconds).not_nil!
      snapshot.window_ready.should eq(true)
      snapshot.state.should eq(false)
      snapshot.changed.should eq(false)
      snapshot.on_fraction.should be_close(0.6, 1e-9)
      # confidence tracks the latched (off) state: 0.4, eroding toward the
      # 0.3 flip point but not there yet, so the state holds
      snapshot.confidence.should be_close(0.4, 1e-9)
    end

    it "ignores a momentary blip" do
      base = Time.instant
      smoother = TestSmoother.new(10.seconds, 0.7)
      smoother.observe(false, at: base)
      smoother.observe(true, at: base + 8.seconds)
      smoother.observe(false, at: base + 9.seconds)

      snapshot = smoother.poll(base + 10.seconds).not_nil!
      snapshot.state.should eq(false)
      snapshot.changed.should eq(false)
      snapshot.on_fraction.should be_close(0.1, 1e-9)
    end

    it "does not repeatedly report a change once switched" do
      base = Time.instant
      smoother = TestSmoother.new(10.seconds, 0.7)
      smoother.observe(false, at: base)
      smoother.observe(true, at: base + 1.second)

      first = smoother.poll(base + 11.seconds).not_nil!
      first.state.should eq(true)
      first.changed.should eq(true)

      # steady state on a later poll: still on, but no new transition
      second = smoother.poll(base + 12.seconds).not_nil!
      second.state.should eq(true)
      second.changed.should eq(false)
    end
  end

  describe "confidence in the current state" do
    # Confidence is the fraction of the evaluated window spent in the current
    # output state. It starts at the threshold when a state is entered, rises
    # toward 1.0 as evidence agrees, and erodes toward the flip point (which is
    # 1 - threshold) as evidence disagrees. On reaching the flip point the state
    # switches and the new state's confidence starts back at the threshold.
    it "erodes from the current state down to the flip point, then flips to the threshold" do
      base = Time.instant
      smoother = TestSmoother.new(10.seconds, 0.7)
      smoother.observe(true, at: base)
      # sensor drops out well into the window; presence output stays latched on
      smoother.observe(false, at: base + 6.seconds)

      # window ready: 6s on / 4s off => still on, confidence eroding at 0.6
      first = smoother.poll(base + 10.seconds).not_nil!
      first.state.should eq(true)
      first.changed.should eq(false)
      first.confidence.should be_close(0.6, 1e-9)

      # further into the off period: 4s on / 6s off => still on, confidence 0.4
      second = smoother.poll(base + 12.seconds).not_nil!
      second.state.should eq(true)
      second.changed.should eq(false)
      second.confidence.should be_close(0.4, 1e-9)

      # on_fraction reaches the 0.3 flip point => state flips off, and the new
      # (off) state's confidence starts at the 0.7 threshold
      third = smoother.poll(base + 13.seconds).not_nil!
      third.state.should eq(false)
      third.changed.should eq(true)
      third.confidence.should be_close(0.7, 1e-9)
    end

    it "honestly reports confidence below the flip point during warm-up" do
      base = Time.instant
      smoother = TestSmoother.new(10.seconds, 0.7)
      smoother.observe(true, at: base)
      smoother.observe(false, at: base + 1.second)

      # window not full yet: the initial state cannot flip, so confidence is
      # reported as-is even though it has dipped below the 0.3 flip point
      snapshot = smoother.poll(base + 5.seconds).not_nil!
      snapshot.window_ready.should eq(false)
      snapshot.state.should eq(true) # latched on, no flip permitted yet
      snapshot.changed.should eq(false)
      snapshot.confidence.should be_close(0.2, 1e-9)
    end
  end

  describe "on/off fractions" do
    it "always sum to one over an evaluated window" do
      base = Time.instant
      smoother = TestSmoother.new(10.seconds, 0.7)
      smoother.observe(false, at: base)
      smoother.observe(true, at: base + 3.seconds)
      smoother.observe(false, at: base + 7.seconds)

      snapshot = smoother.poll(base + 12.seconds).not_nil!
      (snapshot.on_fraction + snapshot.off_fraction).should be_close(1.0, 1e-9)
    end
  end

  describe "input validation" do
    it "ignores repeated identical observations" do
      base = Time.instant
      smoother = TestSmoother.new(10.seconds, 0.7)
      smoother.observe(true, at: base)
      smoother.observe(true, at: base + 1.second)
      smoother.observe(true, at: base + 2.seconds)

      # repeats collapse to a single accumulating segment: fully confident on
      snapshot = smoother.poll(base + 10.seconds).not_nil!
      snapshot.state.should eq(true)
      snapshot.on_fraction.should be_close(1.0, 1e-9)
    end

    it "enforces monotonically increasing observation timestamps" do
      base = Time.instant
      smoother = TestSmoother.new(10.seconds)
      smoother.observe(false, at: base + 5.seconds)
      expect_raises(ArgumentError, /monotonic/) do
        smoother.observe(true, at: base + 4.seconds)
      end
    end

    it "rejects a poll before the first observation" do
      base = Time.instant
      smoother = TestSmoother.new(10.seconds)
      smoother.observe(true, at: base + 5.seconds)
      expect_raises(ArgumentError, /precedes the first observation/) do
        smoother.poll(base + 4.seconds)
      end
    end

    it "rejects a poll before the latest observation" do
      base = Time.instant
      smoother = TestSmoother.new(10.seconds)
      smoother.observe(false, at: base)
      smoother.observe(true, at: base + 5.seconds)
      expect_raises(ArgumentError, /precedes the latest observation/) do
        smoother.poll(base + 4.seconds)
      end
    end
  end
end
