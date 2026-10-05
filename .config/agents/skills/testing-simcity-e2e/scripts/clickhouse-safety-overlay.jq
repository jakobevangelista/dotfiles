if (.services.clickhouse? | type) != "object" then
  error("expected exact Compose service: clickhouse")
elif ((.services.clickhouse.image // "") | startswith("clickhouse/clickhouse-server:") | not) then
  error("refusing to alter unexpected clickhouse service image")
else
  {
    services: {
      clickhouse: {
        restart: "no",
        logging: {
          driver: "local",
          options: {
            "max-size": "20m",
            "max-file": "3"
          }
        }
      }
    }
  }
end
