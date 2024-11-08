## TODO

- [] Move old code to Lua modules
- [] Function to generate UUID
- [] When request comes, extract new schema field "async_request_id" or, generate new UUID and store it
- [] Store custom entity with TTL (kong cache?)
- [] When response comes from timer, store custom entity response with "async_request_id"
...

# Proof Of Concepts

WIP

NOTE: This repo only contains code; the README are just a few commands or notes I added for myself. For a better insight, check https://github.com/ilozano2/post-kong-async-plugin

## Useful

Using `timer.ng` requires adding the lua library. For development purposes, I can add the library into the image

```shell
DOCKER_BUILDKIT=0 docker build -t kong-gateway_my-plugin:3.8-0.0.1 --pull=false .
```

```shell
curl -Ls https://get.konghq.com/quickstart | \
 bash -s -- -r "" -i kong-gateway_my-plugin -t 3.8-0.0.1
```

Adding Service, Plugin, Route

```shell
curl -i -s -X POST http://localhost:8001/services \
   --data name=whatever_service \
   --data url='https://whatever.requestcatcher.com'
curl -is -X POST http://localhost:8001/services/whatever_service/plugins \
   --data 'name=my-plugin'
curl -i -X POST http://localhost:8001/services/whatever_service/routes \
   --data 'paths[]=/mock' \
   --data name=example_route
```  

```shell
docker ps | grep kong-gateway_my-plugin | awk '{print $1}' | xargs docker logs -f
```

Send request to my route
```shell
curl -i http://localhost:8000/mock/anything
```

In kong shell

```shell
tail -f  /kong-plugin/servroot/logs/error.log
```


docker exec -it $(docker ps | grep postgre | awk '{print $1}') bash


psql -U kong kong_tests


select * from async_request_response;