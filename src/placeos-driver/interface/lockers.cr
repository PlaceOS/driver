require "json"
require "./locatable"

abstract class PlaceOS::Driver
  module Interface::Lockers
    include Interface::Locatable

    # inherit this to extend with additional locker information
    class PlaceLocker
      include JSON::Serializable

      # identifier for location services
      getter location : Symbol = :locker

      # the locker system ids
      property bank_id : String | Int64
      property locker_id : String | Int64

      # the text on the outside of the locker
      property locker_name : String

      # is the current locker allocated
      property? allocated : Bool?

      # when the locker is released if known / enabled in the locker system
      @[JSON::Field(converter: Time::EpochConverter, type: "integer", format: "Int64")]
      property expires_at : Time? = nil

      # a single field that can be used to uniquely identify a locker
      # should not clash with other systems and ideally be usable to
      # identify the user who is allocated to the locker (via a lookup function)
      property mac : String? = nil

      # metadata for locating the locker (if known) - placeos zone ids
      property building : String? = nil
      property level : String? = nil
    end

    # allocates a locker now, the allocation may expire
    abstract def locker_allocate(
      # PlaceOS user id
      user_id : String,

      # the locker location
      bank_id : String | Int64,

      # allocates a random locker if this is nil
      locker_id : String | Int64? = nil,

      # attempts to create a booking that expires at the time specified
      expires_at : Int64? = nil
    ) : PlaceLocker

    # return the locker to the pool
    abstract def locker_release(
      bank_id : String | Int64,
      locker_id : String | Int64,

      # release / unshare just this user - otherwise release the whole locker
      owner_id : String? = nil
    ) : Nil

    # a list of lockers that are allocated to the user
    abstract def lockers_allocated_to(user_id : String) : Array(PlaceLocker)

    abstract def locker_share(
      bank_id : String | Int64,
      locker_id : String | Int64,
      owner_id : String,
      share_with : String
    ) : Nil

    abstract def locker_unshare(
      bank_id : String | Int64,
      locker_id : String | Int64,
      owner_id : String,
      # the individual you previously shared with (optional)
      shared_with_id : String? = nil
    ) : Nil

    # a list of user-ids that the locker is shared with.
    # this can be placeos user ids or emails
    abstract def locker_shared_with(
      bank_id : String | Int64,
      locker_id : String | Int64,
      owner_id : String
    ) : Array(String)

    abstract def locker_unlock(
      bank_id : String | Int64,
      locker_id : String | Int64,

      # sometimes required by locker systems
      owner_id : String? = nil,
      # time in seconds the locker should be unlocked
      # (can be ignored if not implemented)
      open_time : Int32 = 60
    ) : Nil

    # ========================================
    # Public Lockers Interface
    # ========================================
    # Overwrite these to add additional functionality and checks

    protected def __ensure_user_id__ : String
      user_id = invoked_by_user_id
      raise "current user not known in this context" unless user_id
      user_id.as(String)
    end

    def locker_allocate_me(
      bank_id : String | Int64,
      locker_id : String | Int64? = nil,
      expires_at : Int64? = nil
    )
      locker_allocate(__ensure_user_id__, bank_id, locker_id, expires_at)
    end

    def locker_release_mine(
      bank_id : String | Int64,
      locker_id : String | Int64
    )
      locker_release(bank_id, locker_id, __ensure_user_id__)
    end

    def lockers_allocated_to_me
      lockers_allocated_to __ensure_user_id__
    end

    def locker_share_mine(
      bank_id : String | Int64,
      locker_id : String | Int64,
      share_with : String
    )
      locker_share(bank_id, locker_id, __ensure_user_id__, share_with)
    end

    def locker_unshare_mine(
      bank_id : String | Int64,
      locker_id : String | Int64,
      shared_with_id : String? = nil
    )
      locker_unshare(bank_id, locker_id, __ensure_user_id__, shared_with_id)
    end

    def locker_shared_with_others(
      bank_id : String | Int64,
      locker_id : String | Int64
    )
      locker_shared_with(bank_id, locker_id, __ensure_user_id__)
    end

    def locker_unlock_mine(
      bank_id : String | Int64,
      locker_id : String | Int64,
      open_time : Int32 = 60
    )
      locker_unlock(bank_id, locker_id, __ensure_user_id__, open_time)
    end
  end
end
