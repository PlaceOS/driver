require "http"

# driver level HTTP helpers, these are available on all transports via
# `Transport#http` so are always compiled, regardless of the transports
# selected by the discovery settings
class PlaceOS::Driver
  {% for method in %w(get post put head delete patch options) %}
    # Executes a {{method.id.upcase}} request on the client connection.
    #
    # The response status will be automatically checked and an error raised if unsuccessful
    #
    # Macro expansion allows this to obtain context from a surround method and
    # use method arguments to build an appropriate request structure.
    #
    # Us *as* to specify a JSON parse-able model that the response should be
    # piped into. If unspecified a `JSON::Any` will be returned.
    private macro {{method.id}}_request(path, params = URI::Params.new, headers = HTTP::Headers.new, body = nil, secure = false, concurrent = false, as model = nil)
      {% verbatim do %}
        path = {{path}}
        headers = {{headers}}

        # Build a body (if required)
        {% if body.is_a? NamedTupleLiteral %}
          headers ||= HTTP::Headers.new
          headers["Content-Type"] = "application/json"
          body = JSON.build do |json|
            json.object do
              {% for key, value in body %}
                json.field {{key.stringify}}, {{value}}
              {% end %}
            end
          end
        {% else %}
          body = {{body}}
        {% end %}

        concurrent = {{concurrent}}
        secure = {{secure}}
      {% end %}

      # Exec the request
      response = transport.http(
        method: {{method.upcase.stringify.id}},
        path: path,
        body: body,
        params: params,
        headers: headers,
        concurrent: concurrent,
        secure: secure,
      )
      unless response.success?
        logger.debug { response.body }
        raise "unexpected response #{response.status_code}\n#{response.body}"
      end
      # Parse the response
      {% verbatim do %}
        {% if model %}
          {{model}}.from_json response.body
        {% else %}
          if response.body.empty?
            JSON::Any.new nil
          else
            JSON.parse response.body
          end
        {% end %}
      {% end %}
    end
  {% end %}

  # Implement the HTTP helpers
  protected def http(method, path, body : ::HTTP::Client::BodyType = nil,
                     params : Hash(String, String?) | URI::Params = URI::Params.new,
                     headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new,
                     secure = false, concurrent = false) : ::HTTP::Client::Response
    transport.http(method, path, body, params, headers, secure, concurrent)
  end

  protected def get(path,
                    params : Hash(String, String?) | URI::Params = URI::Params.new,
                    headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new,
                    secure = false, concurrent = false)
    transport.http("GET", path, params: params, headers: headers, secure: secure, concurrent: concurrent)
  end

  protected def post(path, body : ::HTTP::Client::BodyType = nil,
                     params : Hash(String, String?) | URI::Params = URI::Params.new,
                     headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new,
                     secure = false, concurrent = false)
    transport.http("POST", path, body, params, headers, secure, concurrent)
  end

  protected def put(path, body : ::HTTP::Client::BodyType = nil,
                    params : Hash(String, String?) | URI::Params = URI::Params.new,
                    headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new,
                    secure = false, concurrent = false)
    transport.http("PUT", path, body, params, headers, secure, concurrent)
  end

  protected def patch(path, body : ::HTTP::Client::BodyType = nil,
                      params : Hash(String, String?) | URI::Params = URI::Params.new,
                      headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new,
                      secure = false, concurrent = false)
    transport.http("PATCH", path, body, params, headers, secure, concurrent)
  end

  protected def delete(path, body : ::HTTP::Client::BodyType = nil,
                       params : Hash(String, String?) | URI::Params = URI::Params.new,
                       headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new,
                       secure = false, concurrent = false)
    transport.http("DELETE", path, body, params, headers, secure, concurrent)
  end
end
