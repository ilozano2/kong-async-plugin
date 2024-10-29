-- daos.lua
local typedefs = require "kong.db.schema.typedefs"


return {
  -- this plugin only results in one custom DAO, named `keyauth_credentials`:
  {
    name                  = "async_request_response", -- the actual table in the database
    primary_key           = { "id" },
    generate_admin_api    = true,
    admin_api_name        = "async-request-responses",
    fields = {
      {
        -- a value to be inserted by the DAO itself
        -- (think of serial id and the uniqueness of such required here)
        id = typedefs.uuid,
      },
      {
        -- also interted by the DAO itself
        created_at = typedefs.auto_timestamp_s,
      },
      {
        is_finished = {
            type = "boolean",
            default = false
        }
      },
      {
        res_status = {
            type    = "integer",
            default = 202
        }
      },
      {
        res_body = {
            type = "string",
            default = ngx.null
        }
      },
    },
  },
}