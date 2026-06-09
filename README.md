# PlaceOS Driver

[![CI](https://github.com/PlaceOS/driver/actions/workflows/ci.yml/badge.svg)](https://github.com/PlaceOS/driver/actions/workflows/ci.yml)

The framework for running drivers on PlaceOS.

## Requirements

* libssh2 required for SSH support

## Transport selection

Only the transports a driver declares are compiled into the binary, based on the discovery settings in the driver class body:

| Declaration | Transports compiled |
|---|---|
| `tcp_port 1234` | TCP + SSH |
| `udp_port 1234` | UDP |
| `uri_base "https://..."` | HTTP + websocket |
| none of the above | logic only |

Starting a module with a role the driver was not compiled for raises at module start, for example: `driver was not compiled with HTTP transport support, declare 'uri_base' in the driver to enable it`.

All transports can be forced into a binary with the `-Dplaceos_all_transports` compiler flag or by calling `PlaceOS::Driver.load_all_transports` after requiring the library. The test-harness builds driver binaries with this flag, as `DriverSpecs` launches every driver against a mock raw TCP server (`role: 1`) plus a mock HTTP server, regardless of the transports the driver uses in production.
