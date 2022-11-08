# Triggers and webhooks

Triggers can be used to provide a method of code executing via a webhook.

* The webhook can trigger user defined actions
* A specially formed driver function can be passed the HTTP request details of the webhook and define the response


## Configuring a webhook

When creating a webhook, make sure the `enable webhook` checkbox is selected

* This adds the webhook as a condition to trigger the actions
* you can add additional conditions


### User defined actions:

* you can configure actions to occur when the webhook fires / conditions are met


### Specially formed driver:

* select the method types that can be used to trigger hook (GET, POST etc)
* you can modify these after creation by clicking the edit button

https://github.com/PlaceOS/drivers/blob/master/drivers/cisco/meraki/dashboard.cr

```crystal
EMPTY_HEADERS = {} of String => String

def webhook_handler(method : String, headers : Hash(String, Array(String)), body : String)
  # Method: GET, POST, PATCH etc
  # HTTP Headers
  # The body content

  # Return a 200 response
  {HTTP::Status::OK.to_i, EMPTY_HEADERS, "Response body"}
end
```

NOTE:: Once added to a system, you need to also explicitly enable this function.


## Triggering a webhook


### User defined actions:

the webhook URL looks like:

```
/api/engine/v2/webhook/trig-id/notify?secret=[secret-key]
```


### Specially formed driver:

Once you've

* added to the desired system
* explicitly checked `execute enabled`

the webhook URL looks like:

```
/api/engine/v2/webhook/trig-id/notify/[secret-key]/[Module-name]/[Module-index]/[function-name]
```
OR
```
/api/engine/v2/webhook/trig-id/notify?secret=[secret-key]&exec=true&mod=[ModuleName]&index=[index-integer]&method=[method-name]
```

i.e. (index defaults to 1)

POST http://localhost:8080/api/engine/v2/webhook/trig-FHSLZ-aE_04/notify?secret=ae5b062ae1f56032936c174de81b&exec=true&mod=Testing&method=webhook_handler
