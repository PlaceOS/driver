# Command Line Options

Handled by

* Command line parser: `./src/driver.cr`
* Discovery and Metadata: `./src/driver/utilities/discovery.cr`


## Discovery and Defaults

Outputs the default settings defined by the driver.

`driver -d` or `driver --defaults`

This includes things like:

* default settings
* descriptive name
* generic name
* description
* default ports

Looks like:

```yaml

{
  "descriptive_name": "Screen Technics Control",
  "generic_name": "Screen",
  "tcp_port": 3001,
  "default_settings": "{\"json\": \"formatted hash\"}",

  # All the possible keys
  "description": "to be considered markdown format",
  "udp_port": 3001,
  "uri_base": "https://twitter.com",
  "makebreak": true
}

```

## Metadata

outputs driver metadata

`driver -m` or `driver --metadata`

* functions: list of publicly exposed functions
* implements: list of interfaces (Powerable, Switchable etc) implemented by the driver
* requirements: list of external requirements for ideal operation (drivers in the system and what interfaces they should implement)

Spec in `./spec/driver_spec.cr`


## Process Launcher

Launches the program in operational mode. This is typically only performed by Engine Core or the testing framework.

`driver -p` or `driver --process`

* STDOUT is used for logging
* STDERR is used for communicating with Engine Core
* STDIN is used by Engine Core to communicate with the process
