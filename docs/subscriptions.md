# Subscriptions

There are three types of subscriptions.

* channel - these are user defined events
* direct - these subscribe directly to a module (module id + status name)
* indirect - these subscribe to the system indirection (system id + module name + module index + status)

The main complexity is then tracking indirect subscriptions.


## How it works

Every time a change of state occurs in redis, an event is fired:

* event path: `status/module_id/status_name` this is fired in `./src/storage.cr`

Subscriptions are made to redis and monitored in the `./src/subscriptions.cr`

* Each driver instance has it's own collection of subscriptions, tracked by `./src/proxy/subscriptions`
* The keys that map to actual status variables are stored in `./src/subscriptions/*` along with the callbacks


### Indirect Subscription

Indirect subscriptions have two additional conditions that need to be tracked:

* The device might not exist
* The device mapping might change

Each subscription type defines a method, `def subscribe_to`, which might return `nil` for indirect subscriptions, meaning no actual subscription will occur.
Every time a change in system state occurs:

1. Indirect subscriptions for that system are unsubscribed
2. The subscription is `reset` so that a new lookup will occur
3. The subscriptions are re-subscribed


### Detecting system lookup changes

There is a special event that occurs when a system updated occurs.

* Event name: `lookup-change` which passes a system id.
* This triggers `def remap_indirect` in `./src/subscriptions.cr`

The `lookup-change` event is fired by the Triggers micro-service
