local typedefs = require "kong.db.schema.typedefs"

return {
  name = "access-key-auth-with-grpc",
  fields = {
    { config = {
        type = "record",
        fields = {
          { second = { type = "number", gt = 0 }, },
          { minute = { type = "number", gt = 0 }, },
          { hour = { type = "number", gt = 0 }, },
          { day = { type = "number", gt = 0 }, },
          { month = { type = "number", gt = 0 }, },
          { year = { type = "number", gt = 0 }, },
          { accessKey_header_name = typedefs.header_name },
          { chainType_header_name = typedefs.header_name },
          { fault_tolerant = { type = "boolean", required = true, default = true }, },
          { keySymbol = { type = "string", required = true, default = "key" }, },
          { ifCutReq = { type = "boolean", required = true, default = false }, },
          { cutReqChainType = { type = "string" }, },
          { redis_host = typedefs.host },
          { redis_port = typedefs.port({ default = 6379 }), },
          { redis_password = { type = "string", len_min = 0 }, },
          { redis_ssl = { type = "boolean", required = true, default = false, }, },
          { redis_ssl_verify = { type = "boolean", required = true, default = false }, },
          { redis_server_name = typedefs.sni },
          { redis_timeout = { type = "number", default = 2000, }, },
          { redis_database = { type = "integer", default = 0 }, },
        },
      },
    },
  },
}
