# Data-Center-Gateway

## 1. Introduction

This document is a tutorial for Data Center Operators to install and configure their own gateways

### 1.1 Hardware Requirements

#### Minimum Requirements

- 4 CPU
- Memory: 8GB
- Disk: 50GB SSD

#### Recommended Requirements

- 8 CPU
- Memory: 32GB
- Disk: 100GB SSD

### 1.2 Prerequisites

| Software  | Version  |
| ----- | ----- | 
| redis | 6.0.5+ |
| git | 2.39.0+ |
| docker-ce | 20.10.21+ |
| docker-compose | 1.25.5+ |
| [Spartan-I Chain Default Node](https://github.com/BSN-Spartan/NC-Ethereum) | - |
| [Data Center Management System](https://github.com/BSN-Spartan/Data-Center-System) |1.1.0+|
| tree (optional) | 1.6.0 |

### 1.3 Project Dependencies

kong: Kong API gateway

postgresql: database of the gateway

konga: visual configuration web service of the gateway

kong-service: microservice of the gateway

redis: used to store the user's access key, the gateway's TPS and TPD flow restriction is also based on redis implementation


## 2. Installation: 

Create a working directory and clone the project: 

```shell
git clone https://github.com/BSN-Spartan/Data-Center-Gateway.git
```

Now, the structure of Kong Gateway is shown as below:

```shell
[root@localhost bsn]# tree -L 3 Data-Center-Gateway/
Data-Center-Gateway/
├── docker-compose.yaml
├── kong
│   ├── conf
│   │   ├── kong.conf
│   │   ├── kong.yaml
│   │   ├── nginx_kong.lua
│   │   ├── nginx_kong_stream.lua
│   │   └── start.sh
│   ├── logs
│   │   ├── access.log
│   │   ├── admin_access.log
│   │   ├── error.log
│   │   ├── status_error.log
│   │   ├── tcp_access.log
│   │   └── tcp_error.log
│   └── plugins
│       ├── access-key-auth-with-grpc
│       ├── access-key-auth-with-http
│       └── deck
└── super-kong-service
    ├── config
    │   └── config.yaml
    └── super-kong-service

8 directories, 15 files
```

Grant read/write/execute permissions to `Data-Center-Gateway/kong` and `Data-Center-Gateway/super-kong-service` directories, then execute the following commands: 

```shell
chmod 777 -R Data-Center-Gateway/kong
chmod 777 -R Data-Center-Gateway/super-kong-service
```

Edit `Data-Center-Gateway/super-kong-service/config/config.yaml`: 

##### Example of `config.yaml`: 

```shell
Redis:
  redisHost: localhost:6379    // redis_IP:Port  Need to be consistent with the plugin configuration below
  redisPW: "password"		   // Redis password   Need to be consistent with the plugin configuration below
  redisDb: 0		           // Redis database  Need to be consistent with the plugin configuration below
KeySymbol: "spartan"  //symbol of the Redis storage key，Needs to be consistent with the keySymbol configured in the plugin below
ServerPort: 18899   		   // microservice API port number
```

Start the gateway by Docker: 

```shell
docker network create kong-net              // Create a Docker network to allow the containers to discover and communicate with each other
docker-compose -f docker-compose.yaml up -d // Start the container
// docker-compose -f docker-compose.yaml down  // Stop the container
```

Import the gateway initialization configuration (**this operation only needs to be performed once after the first start of the gateway and need not to re-import afterwards**):

Access the kong gateway container: 

```shell
docker exec -it super-kong bash
```

Run the command in the container: 

```shell
cd /usr/local/kong/ && deck sync --config /usr/local/kong/kong.yaml
```

The contains has been started: 

![image-20221111151802708](./image/docker.png)



## 3. Configuration

### 3.1 Konga Initialization

Initialize konga, open konga in the browser: 

http://Kong_gateway_IP:1337

Register a user: 

![image-20221109094944436](./image/konga.png)

After successful registration and login, configure the Kong Admin URL: 

![image-20221109095132372](./image/konga-conn.png)

Username: admin // this value can be defined by yourself

URL: http://super-kong:8001

`super-kong` is the container's name of Kong gateway

8001 is the admin_api port of Kong gateway

konga communicates with Kong by Docker's internal virtual network

You can connect to Kong gateway after correctly configuring the parameters above, and then manage the gateway configuration.

The configuration of gateway initialization was imported in prior, Kong gateway can run normally just by adding the upstream configuration and editing the configuration of the plug-in.


### 3.2 Configure Upstream

![image-20221108143011912](./image/upstream.png)

**The chainType in the upstream name must be the same as the one in the user's request path, otherwise the transaction cannot be forwarded properly!**

The upstream name format is (lowercase): chainType + "-" + chainPort 

Example: spartanone-rpc

The upstream name must be configured in this format, and other parameters are optional.

First you need to enter your upstream name in the format, then click the Submit button to save it, then click the `Details` button, and finally select `Targets` and configure your node address and port.



![image-20221111145527194](./image/upstream-name.png)

Then, configure Targets in the format of `<Kong VM Public IP>:<Port>`   //This is the rpc address and port of your node, make sure kong can communicate directly with your node address properly

Example: 10.0.51.134:8545

**Targets need to be configured with at least one, which is the address of the node that will ultimately receive the transaction.**

![image-20221108143109646](./image/target.png)


### 3.3 Configure Plugins

Plugin name: `access-key-auth-with-http`

Modify the Redis configuration to match the Redis configuration in microservices;

Change keySymbol to match the symbol of Redis storage key in microservices;

Leave other parameters unchanged.

![image-20221111145823871](./image/p1.png)



Plugin name: `access-key-auth-with-grpc`

Modify the Redis configuration to match the Redis configuration in microservices;

Change keySymbol to match the symbol of Redis storage key in microservices;

Leave other parameters unchanged.

![image-20221111145941725](./image/p2.png)


### 3.4 Configure Consumers

Create a user and configure Basic Auth: 

The username and password need to be configured into Data Center Operator's operations and maintenance system, and will be used when the system requests the gateway microservice interface.

Username: admin // this value can be defined by yourself

![image-20221111150227731](./image/consumer1.png)

![image-20221111150257902](./image/consumer2.png)

![image-20221111150319162](./image/consumer3.png)

![image-20221111150342260](./image/consumer4.png)



## 4. Key Parameters

### 4.1 Key Configurations

1. The Redis configuration in the microservice needs to be consistent with the Redis configuration in the 2 plugins, otherwise it cannot authenticate and limit the flow.

2. The name of the pubic chainType should be consistent with the chainType in the upstream name, otherwise the requests cannot be forwarded to the correct target node

3. When creating the Consumer in the gateway, the username and password of Basic Auth need to be configured to the operations and maintenance system, otherwise the system cannot request the gateway microservice interface.

4. For security reason, the port of Kong gateway related management interface is not open, see docker-compose file for more details. The communication between kong, konga and microservices is via Docker's virtual network.

5. Official development documentation of Kong Gateway: https://docs.konghq.com/gateway/2.8.x/



### 4.2 Public Ports of Kong Gateway 

18601: http/websocket port

18602: https/websockets port

18603: grpcs port

18605: grpc port



### 4.3 Key Request Parameters of Kong Gateway

Access key: accessKey

Target chain: chainType

Interface type of user requests: chainPort

### 4.4 Kong Gateway Request Format

#### 4.4.1 HTTP Request

https://[domain_name:port]/api/[accessKey]/[chainType]/[chainPort]/[path_on_chain]

*Note: `path_on_chain` is optional*

Example: https://spartangate.com:18601/api/015416c06ef74ac38a92521792f97e7d/spartanone/rpc

#### 4.4.2 Websocket Request

wss://[domain_name:port]/api/[accessKey]/[chainType]/ws/[path_on_chain]

*Note: `path_on_chain` is optional*

Example: wss://spartangate.com:12345/api/015416c06ef74ac38a92521792f97e7d/spartanone/ws

#### 4.4.3 grpc Request

[domain_name:port]

#### 4.4.4 Request Header

x-api-key:[accessKey]

x-api-chain-type:[chainType]


### 4.5 Verification Steps

1. Obtain gateway access information in the data center portal.
2. Request the gateway interface in the correct format and verify if the request can be successful.

*Note: Make sure to correctly configure the [accessKey], [chainType] and[chainPort] parameters.*



## 5. Resources

#### Installation and configuration of Redis: 

github: https://github.com/redis/redis

Document: https://redis.io/docs/getting-started/