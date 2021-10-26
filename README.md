# netns-cli

Simple cli to create netns to limit outbound IP address. 

## Requirements

- [eli 0.15.2 or newer](https://github.com/cryon-io/eli/releases)

## Usage

```sh
# create namespace
eli netns-cli.lua --setup=<netns name> --outbound-addr=<ipv4> -p <ipv4>:<hport>:<cport>/<proto>

# delete namespace
eli netns-cli.lua --remove=<netns name>

# reapply iptable rules
eli netns-cli.lua --apply-iptables=<netns name>
```

# Build

```sh
eli ./tools/amalg.lua -o ./bin/netns-cli.lua -s cli.lua netns ip
```