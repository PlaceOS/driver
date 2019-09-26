# Core Control Protocol

* Handled by `./src/engine-driver/protocol.cr`
* Engine Core communicates with Engine Drivers over STDIN / STDERR.
* Drivers inherit the STDOUT used by Engine Core for logging.


## Wire Format

Messages are written as message length (binary unsigned 32bit number) followed by the JSON payload


## Processing Commands

* Commands are defined by the `EngineDriver::Protocol::Request` class.
* Incoming requests are buffered and tokenised `def consume_io`
* Commands are then asynchronously dispatched `def process(message)`

Spec in `./spec/protocol_spec.cr`

### Requests and timeouts

* Requests expecting a reply from Engine Core are tracked by `@tracking`, `@current_requests` and `@next_requests`
* A rolling timeout window errors requests where no response has been received after 2 minutes
* Responses to requests are channeled directly to the requestor, bypassing the typical dispatch callback processes

Spec in `./spec/driver_proxy_spec.cr`


## Command Listing

### Start

* Starts an instance of the current driver
* Expects payload to contain:
  * id: of the instance being started (will ignore if already running)
  * payload: is expected to be JSON `DriverModel` conforming to: `./src/engine-driver/driver_model.cr`
* Response is expected to be either an error (driver was not loaded) or success (an instance is running)
* Success response is the original request with no payload

Spec in

* `./spec/process_manager_spec.cr`
* `./spec/helper.cr` (<-- code resides here in `def self.process`)

### Stop

* Stops an instance of the current driver
* Only requires the ID of the instance to stop
* No reply is required

Spec in `./spec/process_manager_spec.cr`

### Update

Updates settings only. Other driver model updates are applied by stopping and starting the instance.

* Provides new settings to the instance
* Expects payload to contain:
  * id: of the instance to be updated
  * payload: the settings data for the driver (not the full driver model)
* No reply is required

Spec in `./spec/process_manager_spec.cr`

### Terminate

* Gracefully stops all the driver instances running.
* Kills the driver process.
* Engine Core will Kill 9 the process if not terminated after an undisclosed amount of time

Spec in `./spec/process_manager_spec.cr`

### Exec

Executes a function on a running instance.

* Expects payload to contain:
  * id: of the instance to be called
  * payload: the function and functions arguments (see: `./src/engine-driver.cr` => `KlassExecutor`, example below)
  * reply: the ID of the driver or process that initiated the request (for routing reply back)
  * seq: senders sequence number, so the request can be tracked by the requestor
* A reply is required
  * The return value of the function that was called is converted to JSON and set as the reply payload
  * If the value cannot be converted to JSON a `nil` response is returned

Futures and Promises are resolved before being returned as a reply (`#get` called on any object that responds to it)
There is a 2 minute timeout for responses, so functions expected to take longer should provide alternative means to
obtain the response if it is required.

Example named parameter payload format:

```json
{
  "__exec__": "function_name",
  "function_name": {
    "argument1": 1,
    "argument2": 2
  }
}

```

Example regular parameter payload format:

```json
{
  "__exec__": "function_name",
  "function_name": [1, 2]
}

```

For more examples see:

* `./spec/driver_spec.cr` (primary tests)
* `./spec/process_manager_spec.cr`


### Debug

* Turns on debugging in the instance requested
* Expects payload to contain:
  * id: of the instance to debug
* No reply is required

Spec in

* `./spec/process_manager_spec.cr`
* `./spec/logger_spec.cr`


### Ignore

* Turns off debugging in the instance requested
* Expects payload to contain:
  * id: of the instance to disable debugging
* No reply is required

Spec in

* `./spec/process_manager_spec.cr`
* `./spec/logger_spec.cr`


## Debug notification (Driver -> Core)

* Sends a debug message to core for routing to a client
* Expects payload to contain:
  * id: of the instance producing the message
  * payload: JSON array [severity, message]
* No reply is required

Spec in `./spec/logger_spec.cr`


## Save Setting (Driver -> Core)

defined in `./src/engine-driver.cr`

* Requests core saves a setting on behalf of the driver
* Expects payload to contain:
  * id: of the instance requesting the setting save
  * payload: JSON that should be merged into the instances settings
* No reply is required
* NOTE:: this will trigger an update notification to occur
