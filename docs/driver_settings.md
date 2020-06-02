# Driver Settings

Driver settings are stored as JSON so values need to be extracted into typed variables.
There are helpers in `./src/placeos-driver.cr` that simplify extracting types


## Extracting Settings

```crystal
# Examples

setting(Array(Int32), :sizes) # => [10, 12, 16, 18]
setting(String, :room_name) # => "Meeting 123"
setting(Bool, :deep, :might_not_exist)? # => nil

setting[:sizes] # => JSON::Any or raise error
setting[:might_not_exist]? # => JSON::Any?

setting.raw(:deep, :dive, :value) # => JSON::Any or raise error
setting.raw?(:deep, :might_not_exist) # => JSON::Any?

```


## Saving Settings

There is a helper for saving settings `def define_setting`

```crystal
define_setting(:key, value)

```

1. Saves the value in the database (replacing any existing settings at that key)
2. Triggers an `on_update` callback
