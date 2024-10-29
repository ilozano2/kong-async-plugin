-- `<plugin_name>/migrations/000_base_my_plugin.lua`
return {
    postgres = {
      up = [[
        CREATE TABLE IF NOT EXISTS "async_request_response" (
          "id"           UUID                         PRIMARY KEY,
          "created_at"   TIMESTAMP WITHOUT TIME ZONE,
          "is_finished"   BOOLEAN,
          "res_status"   SMALLINT,
          "res_body"         TEXT
        );
      ]],
    }
  }