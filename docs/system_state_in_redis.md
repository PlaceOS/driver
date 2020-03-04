# System State and Status Tracking

* Redis is used to track and persist driver state.
* State is also stored in memory to avoid having to goto redis
* State is stored as JSON, so it's more efficient to read state out of data structures built for purpose. Example below:

```crystal
# How to efficiently store state so it can be used efficiently internally
@levels = {} of Symbol => Int32
self[:volume] = @levels[:volume] = 60

def volume_up(by = 1)
 new_volume = @levels[:volume] + by
 # ...request new volume
end
```

Files implementing this:
* Redis storage: `./src/engine-driver/storage.cr`
* Memory status: `./src/engine-driver/status.cr`


## Redis structures

Spec in

* Driver status: `./spec/storage_spec.cr`
* System indexes: `./spec/driver_proxy_spec.cr`


### Driver Status

Status is stored in a [redis hash](https://redis.io/commands/hset) structure

* The hash is stored at: "status/module_id" (where module ID is the ID of the driver)
* The hash keys are the status variable names.
* The hash values are JSON encoded values

This way drivers don't need know how they are indexed. i.e. drivers update status but not the indirect lookups that are required.


### System Indexes

This is how we look up status related to system indexes.
i.e. System id -> Display_1 -> power status

* System indexes are also stored using a [redis hash](https://redis.io/commands/hset) structure
* The hash is stored at: "system/system_id"
* The hash keys are the driver indexes: "module_name/index" i.e. "Display/1"
* The hash values are the driver id

You can see this implemented in `./src/engine-driver/proxy/system.cr` function `def get_driver`


### Driver Metadata

Each driver stores metadata in Redis so other drivers interacting with it can validate function calls before requesting them.

* Metadata model is defined here: `./src/engine-driver/driver_model.cr`
* Drivers set the redis metadata on initialize `./src/engine-driver.cr`
* System proxy loads the metadata in `def get_driver`
* Driver proxy uses the metadata

Spec in `./spec/driver_proxy_spec.cr`
