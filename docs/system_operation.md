# How the system works

A simple overview of how the system coordinates actions and where data is stored


## API

### Look up a driver ID (i.e. system_id => Display 3)

* Redis stores a cached version of system module indexes at hset key "system\x02system_id"
* Hash keys are: "Display\x021", "Display\x022", "Display\x023" etc
* The hash keys point to the driver ID - if a driver exists

So HSET "system\x02system_id", "Display\x023" => driver_id


### Obtain the status of a driver (i.e. driver_id => power)

* Redis stores a hset at key "status\x02module_id"
* Hash keys are the status variable names
* Hash values are JSON encoded values

So HSET "status\x02module_id", "power" => true / false


### Monitor the status of a driver

* Use `require "engine-driver/proxy/subscriptions"` to monitor subscriptions for each websocket connection
* Always use system ID, module name (i.e. Display_1) and status name to subscribe

This is an indirect subscription, allowing seamless module re-orderiing without re-subscription.
The proxy class simplifies management of each websockets subscriptions


### Execute a function on a module

* Given a system ID and module name, i.e. Display_1, lookup the driver ID (above)
* Using redis, get the driver metadata: "interface\x02driver_id"
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
