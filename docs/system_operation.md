# How the system works

A simple overview of how the system coordinates actions and where data is stored

## API

### Look up a driver ID (i.e. system_id => Display 3)

* Redis stores a cached version of system module indexes at hset key "system/system_id"
* Hash keys are: "Display/1", "Display/2", "Display/3" etc
* The hash keys point to the driver ID - if a driver exists

So HSET "system/system_id", "Display/3" => driver_id

* Use the existing helper at `require "placeos-driver/storage"`

```crystal
status = PlaceOS::Driver::Storage.new(system_id, prefix: "system")
module_name = "Display"
index = 1
system["#{module_name}/#{index}"]? => "module_id" / nil
system["#{module_name}/#{index}"] => "module_id" / raise KeyError.new("not found")
```


### Obtain the status of a driver (i.e. driver_id => power)

* Redis stores a hset at key "status/module_id"
* Hash keys are the status variable names
* Hash values are JSON encoded values

So HSET "status/module_id", "power" => true / false

* Use the existing helper at `require "placeos-driver/storage"`

```crystal
status = PlaceOS::Driver::Storage.new(module_id)
status["power"]? => true / false / nil
status["power"] => true / false / raise KeyError.new("not found")
```


### Monitor the status of a driver

* Use `require "placeos-driver/proxy/subscriptions"` to monitor subscriptions for each websocket connection
* Always use system ID, module name (i.e. Display_1) and status name to subscribe

This is an indirect subscription, allowing seamless module re-ordering without re-subscription.
The proxy class simplifies management of each websockets subscriptions

```crystal
# Should only be a single instance of this class per-process
@@subscriptions = PlaceOS::Driver::Subscriptions.new

# One instance of the subscription proxy per-websocket
subscriber = PlaceOS::Driver::Proxy::Subscriptions.new(@@subscriptions)
subscription_reference = subscriber.subscribe(system_id, module_name, index, status_name) do |sub_reference, message|
  # message is always a JSON string (can be passed directly to the front-end)
end

# To stop listening to an individual subscription
subscriber.unsubscribe(subscription_reference)

# When a websocket is terminated
subscriber.terminate
```


### Execute a function on a module

* Given a system ID and module name, i.e. Display_1, lookup the driver ID (above)
* Using redis, get the driver metadata: "interface/driver_id"
* Check the security to ensure the user can access the function
* Use the consistent hashing algorithm to find the server hosting the driver
* Send the request to the server and proxy the response to the client

Example metadata

```yaml
{
  "functions": {
    # Function name => param name => [accepted data type, optional default value]
    "switch_input": {
      "input": ["String"]
    },
    "add": {
      "a": ["Int32"],
      "b": ["Int32"]
    },
    "perform_task": {
      "name": ["String|Int32"]
    },
    "error_task": {},
    "future_add": {
      "a": ["Int32"],
      # second array element is the default value for param b
      "b": ["Int32", 200]
    }
  },
  # Interfaces this driver implements
  "implements": ["VideoConferenceSpace"],
  # Requirements this driver has for other modules in the system
  # (purely used by backoffice to signal any potential issues)
  "requirements": {
    "Display_1": ["Powerable"],
    "Camera": ["Powerable", "Moveable"]
  },
  # Protected functions
  "security": {
    "support": ["error_task", "future_add"],
    "administrator": ["perform_task"]
  }
}
```


## Engine Core

Should perform the following operations:

1. Monitor and ensure all repositories are loaded (these folders should persist a container restart)
2. Monitor and compile all drivers that are in use (as required)
3. Register with hound dog to re-balance the system
4. Launch drivers that are in use
5. Build system hashes in redis (consistent hash of system id == instance in charge of building that data structure)
5. Start modules on those drivers (once all drivers are running)
   * See `core_control_protocol.md`
   * Also `placeos-driver/engine-specs/runner.cr`
6. Mark self as ready
7. Once all Engine Core instances are ready, engine core leader to signal system ready
   * Use a channel called `system`
   * `PlaceOS::Driver::Storage.redis_pool.publish("engine/system", "ready")`
