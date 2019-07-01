# Queuing and Transport

You can access the transport at any time without interacting with the queue.
However the queue exists to provide structure to async events, i.e. preventing a send while waiting for a response.

* Queue is defined here: `./src/engine-driver/queue.cr`
  * Queued Tasks are here: `./src/engine-driver/task.cr`
* Transport files: `./src/engine-driver/transport*`


## The Queue

Each driver instance has it's own command queue. The queue is:

* A priority queue (0 == low priority) with (99+ == higher priority)
* A named queue, where if a new item is added with the same name as an existing item it will override the existing item
* The queue is stateful with online and offline modes of operation. Only named commands are accepted when offline.


### Tasks

Tasks have timeouts, can be retried a number of time and define any delays that should be occurring between tasks.

Spec in `./spec/queue_spec.cr`


### Usage

There is `def queue` helper method in `./src/engine-driver.cr` which adds a Task to the instances transport.

```crystal
queue name: :power, delay: 30.milliseconds, priority: 99 do |task|
  # Operation to perform when it is time to run this task.
end

```

The task object is supplied to the task so resolution can occur within the block. However this is not required.
A common scenario would be:

1. Task block is executed
2. Task timeout timer is started
3. Transport received function is called with transport data and a reference to the current task.
4. Transport function can resolve the task

So if the operation in the Task block blocks then the timeouts are not started and the operation should have its own timeouts (such as HTTP requests)

Timers are also not started if the task is resolved in the block.


## Transport

Transports are queue aware, in that they check if there is a currently processing item in the queue and this can effect behaviour.

* Typically, data coming in from a transport will be sent to the `def received` function. (along with any active task)
  * This occurs in `./src/engine-driver/transport.cr` base class method `def process`
* However a task may define a custom received block and in that case the data will be sent there.

```crystal
queue name: :power, delay: 30.milliseconds, priority: 99 do |task|
  # Using the send helper method (implemented by all transports except HTTP)
  transport.send "data", task do |response|
    task.success if String.new(response) == "great"
  end
end

```

The helper method `send` transparently uses the queue in the same way as the example above.

```crystal
# equivalent to the code block above
send "data", name: :power, delay: 30.milliseconds, priority: 99 do |response, task|
  task.success if String.new(response) == "great"
end
```

When using the received function

```crystal
# equivalent to the code blocks above

def send_data
  send "data", name: :power, delay: 30.milliseconds, priority: 99
end

def received(response, task)
  task.success if String.new(response) == "great"
end
```


### Tokenisation

A [tokeniser](https://github.com/spider-gazelle/tokenizer) can be attached to a transport to simplify message processing.

* Typically one would attach this in the `def on_load` callback of a driver
* This allows the tokeniser to be attached or replaced at any point in the connection lifecycle

```crystal
def on_load
  # Buffer messages up to new line tokens
  transport.tokenizer = Tokenizer.new("\n")
end

```
