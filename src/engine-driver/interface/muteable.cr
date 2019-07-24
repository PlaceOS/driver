module EngineDriver::Interface; end

# Splitting up the interfaces allows logic modules to check if the device
# supports the required level of muting. Allowing to it to fallback to an
# intermediary device like a switcher if required.
# i.e. input -> switcher -> LCD (only supporting audio mute)
# a logic module can check if the output supports video muting and fall back
# to the mute function of the switcher

module EngineDriver::Interface::AudioMuteable
  abstract def mute_audio(state : Bool = true, index : Int32 | String = 1)

  def unmute_audio(index : Int32 | String = 1)
    mute_audio false, index
  end
end

module EngineDriver::Interface::VideoMuteable
  abstract def mute_video(state : Bool = true, index : Int32 | String = 1)

  def unmute_video(index : Int32 | String = 1)
    mute_video false, index
  end
end

module EngineDriver::Interface::Muteable
  include EngineDriver::Interface::AudioMuteable
  include EngineDriver::Interface::VideoMuteable

  enum MuteLayer
    Audio
    Video
    AudioVideo
  end

  # When implementing muteable, these should be the preferred defaults
  abstract def mute(
    state : Bool = true,
    index : Int32 | String = 1,
    layer : MuteLayer = MuteLayer::AudioVideo
  )

  def unmute(index : Int32 | String = 1, layer : MuteLayer = MuteLayer::AudioVideo)
    mute false, index, layer
  end

  def mute_video(state : Bool = true, index : Int32 | String = 1)
    mute state, index, MuteLayer::Video
  end

  def mute_audio(state : Bool = true, index : Int32 | String = 1)
    mute state, index, MuteLayer::Audio
  end
end
