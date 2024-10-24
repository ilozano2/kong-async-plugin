local MyPluginHandler = {
  PRIORITY = -1001,
  VERSION = "0.0.1",
}

local http            = require("resty.http")
local cjson           = require("cjson.safe")
local kong            = kong
local ngx             = ngx
local get_header
local subsystem         = ngx.config.subsystem
local set_authority -- TODO
local is_http_module   = subsystem == "http"
if is_http_module then
  get_header = require("kong.tools.http").get_header
  set_authority = require("resty.kong.grpc").set_authority
end

function MyPluginHandler:init_worker()
  -- Use lua-resty-timer-ng to create a background timer for upstream request
  kong.log.err("init_worker_by_lua_block")
  local timer_module        = require("resty.timerng")
  local options             = {}
  MyPluginHandler.timer_sys = timer_module.new(options)
  kong.log.err("Created")
  MyPluginHandler.timer_sys:start()
  kong.log.err("TIMER created: ", self.timer_sys)
end

local byte              = string.byte
local lower             = string.lower
local SPACE = byte(" ")
local COMMA = byte(",")
local QUESTION_MARK = byte("?")
local sub               = string.sub
local gsub              = string.gsub
local find              = string.find
local balancer     = require "kong.runloop.balancer"
local exit              = ngx.exit
local clear_header      = ngx.req.clear_header

local function csv_iterator(s, b)
  if b == -1 then
    return
  end

  local e = find(s, ",", b, true)
  local v
  local l
  if e then
    if e == b then
      return csv_iterator(s, b + 1) -- empty string
    end
    v = sub(s, b, e - 1)
    l = e - b
    b = e + 1

  else
    if b > 1 then
      v = sub(s, b)
    else
      v = s
    end

    l = #v
    b = -1 -- end iteration
  end

  if l == 1 and (byte(v) == SPACE or byte(v) == COMMA) then
    return csv_iterator(s, b)
  end

  if byte(v, 1, 1) == SPACE then
    v = gsub(v, "^%s+", "")
  end

  if byte(v, -1) == SPACE then
    v = gsub(v, "%s+$", "")
  end

  if v == "" then
    return csv_iterator(s, b)
  end

  return b, v
end

local function csv(s)
  if type(s) ~= "string" or s == "" then
    return csv_iterator, s, -1
  end

  s = lower(s)
  if s == "close" or s == "upgrade" or s == "keep-alive" then
    return csv_iterator, s, -1
  end

  return csv_iterator, s, 1
end


local function balancer_execute(ctx)
  local balancer_data = ctx.balancer_data
  local ok, err, errcode = balancer.execute(balancer_data, ctx)
  if not ok and errcode == 500 then
    err = "failed the initial dns/balancer resolve for '" ..
          balancer_data.host .. "' with: " .. tostring(err)
  end
  return ok, err, errcode
end

local function access_after(ctx, var)
  -- Nginx's behavior when proxying a request with an empty querystring
  -- `/foo?` is to keep `$is_args` an empty string, hence effectively
  -- stripping the empty querystring.
  -- We overcome this behavior with our own logic, to preserve user
  -- desired semantics.
  -- perf: branch usually not taken, don't cache var outside
  if byte(ctx.request_uri or var.request_uri, -1) == QUESTION_MARK or var.is_args == "?" then
    var.upstream_uri = var.upstream_uri .. "?" .. (var.args or "")
  end

  local upstream_scheme = var.upstream_scheme

  local balancer_data = ctx.balancer_data
  balancer_data.scheme = upstream_scheme -- COMPAT: pdk

  -- The content of var.upstream_host is only set by the router if
  -- preserve_host is true
  --
  -- We can't rely on var.upstream_host for balancer retries inside
  -- `set_host_header` because it would never be empty after the first -- balancer try
  local upstream_host = var.upstream_host
  if upstream_host ~= nil and upstream_host ~= "" then
    balancer_data.preserve_host = true

    -- the nginx grpc module does not offer a way to override the
    -- :authority pseudo-header; use our internal API to do so
    -- this call applies to routes with preserve_host=true; for
    -- preserve_host=false, the header is set in `set_host_header`,
    -- so that it also applies to balancer retries
    if upstream_scheme == "grpc" or upstream_scheme == "grpcs" then
      local ok, err = set_authority(upstream_host)
      if not ok then
        kong.log.err("failed to set :authority header: ", err)
      end
    end
  end

  local ok, err, errcode = balancer_execute(ctx)
  if not ok then
    return kong.response.error(errcode, err)
  end

  local ok, err = balancer.set_host_header(balancer_data, upstream_scheme, upstream_host)
  if not ok then
    kong.log.err("failed to set balancer Host header: ", err)
    return exit(500)
  end

  -- clear hop-by-hop request headers:
  local http_connection = get_header("connection", ctx)
  if http_connection ~= "keep-alive" and
      http_connection ~= "close"      and
      http_connection ~= "upgrade"
  then
    for _, header_name in csv(http_connection) do
      -- some of these are already handled by the proxy module,
      -- upgrade being an exception that is handled below with
      -- special semantics.
      if header_name == "upgrade" then
        if var.upstream_connection == "keep-alive" then
          clear_header(header_name)
        end

      else
        clear_header(header_name)
      end
    end
  end

  -- add te header only when client requests trailers (proxy removes it)
  local http_te = get_header("te", ctx)
  if http_te then
    if http_te == "trailers" then
      var.upstream_te = "trailers"

    else
      for _, header_name in csv(http_te) do
        if header_name == "trailers" then
          var.upstream_te = "trailers"
          break
        end
      end
    end
  end

  if get_header("proxy", ctx) then
    clear_header("Proxy")
  end

  if get_header("proxy_connection", ctx) then
    clear_header("Proxy-Connection")
  end
end

function MyPluginHandler:access(config)
  kong.log.err("access: ", MyPluginHandler.timer_sys)

  kong.log.err("NGX var: ", type(ngx.var))
  kong.log.err("NGX req: ", type(ngx.req))
  access_after(ngx.ctx, ngx.var)
  local uri = ngx.var.upstream_uri
  local method = ngx.req.get_method() or "GET"
  local headers = ngx.req.get_headers() or {}
  local body = ngx.req.get_body_data()
  --local upstream_uri = ngx.var.scheme .. "://" .. ngx.var.upstream_host .. ngx.var.upstream_uri
  local upstream_uri = "https://" .. ngx.var.upstream_host .. ngx.var.upstream_uri
  
--[[  kong.log.err("NGX headers: ", ngx.req.get_headers())
  kong.log.err("NGX method: ", ngx.req.get_method())
  kong.log.err("URI: ", ngx.var.uri)
  kong.log.err("URL: ", ngx.req.url)
  kong.log.err("uri from me: ", uri)
  kong.log.err("URI: ", ngx.req.uri)
  kong.log.err("Request: ", ngx.var.request_uri)
  kong.log.err("Matcher: ", ngx.ctx.router_matches.uri)
--]]
  local function send_upstream_request(premature)
    if premature then
      return
    end
  
    -- Create a new HTTP client instance
    local httpc = http.new()
  
    -- Send the original request to the upstream (non-blocking)
    ngx.log(ngx.INFO, "The full upstream URL is: ", upstream_uri)
    kong.log.err("NGX headers: ", cjson.encode(headers))
    kong.log.err("NGX method: ", method)
    local res, err = httpc:request_uri(upstream_uri, {
      method = method
      --headers = headers,
      --body = body,
    })
  
    if not res then
      kong.log("Failed to send request to upstream: ", err)
    else
      kong.log("Upstream request sent with status: ", res.status, res.body)
    end
  end


  --local ok, err = MyPluginHandler.timer_sys:every(0.1, send_upstream_request)
  local ok, err = MyPluginHandler.timer_sys:at(0.1, send_upstream_request)
  if not ok then
    kong.log.err("Failed to create timer: ", err)
    return ngx.exit(500) -- Fail-safe if the timer creation fails
  end

  -- Immediately return a 303 response to the client
  ngx.status = 303 -- HTTP status code for "See Other"
  ngx.header["Location"] = "http://another-url"
  ngx.say("Redirecting to another URL...")

  -- Send the response to the client without waiting for the upstream request
  return ngx.exit(303)
end

--[[
local function send_upstream_request()
  -- Create a new HTTP client instance
  local httpc = http.new()

  -- Make the request to the upstream server (non-blocking)
  local res, err = httpc:request_uri(ngx.var.upstream_url, {
    method = ngx.req.get_method(),
    headers = ngx.req.get_headers(),
    body = ngx.req.get_body_data(),
  })

  if not res then
    ngx.log(ngx.ERR, "Failed to send request to upstream: ", err)
  else
    ngx.log(ngx.INFO, "Upstream request sent with status: ", res.status)
  end
end

function MyPluginHandler:access(config)
  -- Schedule the upstream request to be sent asynchronously
  ngx.timer.at(0, send_upstream_request)

  -- Immediately return a 303 response to the client
  ngx.status = 303 -- HTTP status code for "See Other"
  ngx.header["Location"] = "http://another-url"
  ngx.say("Redirecting to another URL...")

  -- Terminate the request and send the response to the client
  return ngx.exit(303)
end
--]]

--[[
function MyPluginHandler:response(conf)
  local httpc = http.new()

  local res, err = httpc:request_uri("https://httpbin.konghq.com/anything", {
    method = "GET",
  })

  if err then
    return kong.response.error(500,
      "Error when trying to access 3rd party service: " .. err,
      { ["Content-Type"] = "text/html" })
  end

  local body_table, err = cjson.decode(res.body)
  kong.log("hello", "world")
  kong.log("hey", body_table)

  if err then
    return kong.response.error(500,
      "Error while decoding 3rd party service response: " .. err,
      { ["Content-Type"] = "text/html" })
  end



  kong.response.set_header(conf.response_header_name, body_table.url)
end
--]]

return MyPluginHandler
