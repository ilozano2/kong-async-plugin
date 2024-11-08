-- DISCLAIMER: This is an Proof of Concept, it is not ready for Production
-- * It has been an iterative process understanding Kong, openresty and timerng
-- * There are hardcoded values to be moved to global variables
-- * There are functions added to the table MyPluginHandler just for simplicity, but they should be moved to proper modules
-- * AsyncAPI doc generation is not implemented
-- * Plugin technical design is not in the scope of this PoC

local MyPluginHandler = {
  PRIORITY = -1001,
  VERSION = "0.0.1",
}

local http            = require("resty.http")
local cjson           = require("cjson.safe")
local kong            = kong
local ngx             = ngx

function MyPluginHandler:access(config)
  kong.log.debug("access: ", MyPluginHandler.timer_sys)

  -- TODO Check I can get Route/Service information (theoretically it is available https://www.youtube.com/watch?v=1sBui6Z0IDc&t=917s)
  -- Otherwise, it seems that `ngx.ctx.balancer_data.scheme` os not calculated
  MyPluginHandler:access_after(ngx.ctx, ngx.var)

  -- TODO Create a table to abstract this information
  local method = ngx.req.get_method()
  local headers = ngx.req.get_headers()
  local body = ngx.req.get_body_data()
  local upstream_uri = ngx.ctx.balancer_data.scheme .. "://" .. ngx.var.upstream_host .. ngx.var.upstream_uri

  local async_id = headers["X-Async-Kong-Id"]
  kong.log.err("Async ID", async_id)
  if async_id then
    local async_entity = MyPluginHandler:search_async_entity(async_id)

    if async_entity then
      kong.log.debug("Found entity", async_entity)
      return MyPluginHandler:recreate_response(async_entity)
    else
      ngx.status = 404
      ngx.header["X-Async-Kong-Id"] = async_id
      ngx.say("Not Found")
      return ngx.exit(404)
    end
  end

  -- Otherwise, continue creating a new async request
  local async_entity = MyPluginHandler:create_async_entity()
  if not async_entity then
    kong.log.err("Failed to create async entity")
    return ngx.exit(500)
  end

  local function send_upstream_request(premature)
    if premature then
      return
    end
  
    -- Create a new HTTP client instance
    local httpc = http.new()
  
    -- Send the original request to the upstream (non-blocking)
    ngx.log(ngx.INFO, "The full upstream URL is: ", upstream_uri)
    kong.log.debug("NGX headers: ", cjson.encode(headers))
    kong.log.debug("NGX method: ", method)
    
    local res, err = httpc:request_uri(upstream_uri, {
      method = method,
      headers = headers,
      body = body,
    })
  
    if not res then
      kong.log("Failed to send request to upstream: ", err)
    else
      local res_status = res.status
      local res_body = res.body
      kong.log("Upstream request sent with status: ", res_status, ",", res_body)

      
      local entity, err = kong.db.async_request_response:update(
        { id = async_entity.id },
        { res_body = res_body , res_status = res_status, is_finished = true }
      )

      if not entity then
        kong.log.err("Error when updating async entity: " .. err)
        return nil
      end
    end
  end


  local ok, err = MyPluginHandler.timer_sys:at(5, send_upstream_request)
  if not ok then
    kong.log.err("Failed to create timer: ", err)
    return ngx.exit(500) -- Fail-safe if the timer creation fails
  end

  ngx.status = 202 -- HTTP status code for "Accepted"
  -- ngx.header["Location"] = request_uri
  ngx.header["X-Async-Kong-Id"] = async_entity.id
  ngx.say("Moved request 'X-Async-Kong-Id: "..async_entity.id.."' to the queue")

  -- Send the response to the client without waiting for the upstream request
  return ngx.exit(202)
end

-- BEGIN Code picked from core because I need to figure out how to get Route/Service information before sending req to upstream (on access)
local get_header
local subsystem         = ngx.config.subsystem
local set_authority -- TODO
local is_http_module   = subsystem == "http"
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
-- END 

-- END Code picked from core because I cannot get Route/Service information at access (TODO it should be there according to https://www.youtube.com/watch?v=1sBui6Z0IDc&t=441s )
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

function MyPluginHandler:access_after(ctx, var)
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

function MyPluginHandler:search_async_entity(id) 
  local entity, err = kong.db.async_request_response:select({
    id = id
  })
  
  if err then
    kong.log.err("Error searching X-Async-Kong-Id [" .. id .. "]: " .. err)
    return nil
  end
  
  if not entity then
    kong.log.err("The X-Async-Kong-Id [" .. id .. "] hasn't match any previous request")
    return nil
  end

  return entity
end

function MyPluginHandler:recreate_response(async_entity)
  if async_entity.is_finished then
    ngx.status = async_entity.res_status
    ngx.header["X-Async-Kong-Id"] = async_entity.id
    ngx.say(async_entity.res_body)

    return ngx.exit(async_entity.res_status)
  else
    ngx.status = 202 -- TODO choose a better approach using different URLs when is_finished=true
    ngx.header["X-Async-Kong-Id"] = async_entity.id
    ngx.say("In progress")

    return ngx.exit(202)
  end

  
end

function MyPluginHandler:create_async_entity()
  local entity, err = kong.db.async_request_response:insert({})
  
  if not entity then
    kong.log.err("Error when inserting async request response: " .. err)
    return nil
  end

  return entity
end
-- END Code picked from core because.. (TODO Move to a module or re-use if possible and need) 

return MyPluginHandler
