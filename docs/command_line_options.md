# Command Line Options

Handled by

* Command line parser: `./src/engine-driver.cr`
* Discovery and Metadata: `./src/engine-driver/utilities/discovery.cr`


## Discovery and Defaults

Outputs the default settings defined by the driver.

`driver -d` or `driver --defaults`

This includes things like:

* default settings
* descriptive name
* generic name
* description
* default ports


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
