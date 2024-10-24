
-- Build

docker build -t kong-gateway_my-plugin:3.8-0.0.1 . 


DOCKER_BUILDKIT=0 docker build -t kong-gateway_my-plugin:3.8-0.0.1 --pull=false .

curl -Ls https://get.konghq.com/quickstart | \
 bash -s -- -r "" -i kong-gateway_my-plugin -t 3.8-0.0.1

curl -i -s -X POST http://localhost:8001/services \
    --data name=example_service --data url='https://httpbin.konghq.com'

curl -is -X POST http://localhost:8001/services/example_service/plugins --data 'name=my-plugin'

curl -i -X POST http://localhost:8001/services/example_service/routes --data 'paths[]=/mock' --data name=example_route
  

docker ps | grep kong-gateway_my-plugin | awk '{print $1}' | xargs docker logs -f


curl -i http://localhost:8000/mock/anything




curl -i -s -X POST http://localhost:8001/services \
   --data name=example_service \
   --data url='https://httpbin.konghq.com'
curl -is -X POST http://localhost:8001/services/example_service/plugins \
   --data 'name=my-plugin'
curl -i -X POST http://localhost:8001/services/example_service/routes \
   --data 'paths[]=/mock' \
   --data name=example_route


tail -f  /kong-plugin/servroot/logs/error.log
