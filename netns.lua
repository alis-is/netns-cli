local _hjson = require"hjson"
local _ip = require"ip"

local _args = cli.parse_args()
local _info, _warn, _error, _success = util.global_log_factory("", "info", "warn", "error", "success")

local _options = {
	publish = {},
	subnet = "172.29.0.0/16",
	nameservers = { "1.1.1.1", "8.8.8.8" },
	subnet6 = "",
	remove = false,
	masquerade = false,
	localhost = false
}

for _, v in ipairs(_args) do
    if v.type == "option" then
		if v.id == "id" then 
			_options.id = v.value
		elseif v.id == "outbound-addr" then 
			_options.outboundAddr = v.value
		elseif v.id == "publish" or v.id == "p"then
			local _val = v.value
			local _,n = _val:gsub(":","")
			if n < 1 or n > 2 then 
				_warn("Invalid port map " .. _val)
				goto CONTINUE
			end
			local _hAddr, _hport, _cport, _proto 
			if n == 1 then 
				_hport, _cport, _proto = _val:match"([^:]*):([^/]*)/?(.*)"
				_hAddr = "0.0.0.0/0"
			else 
				_hAddr, _hport, _cport, _proto = _val:match"([^:]*):([^:]*):([^/]*)/?(.*)"
			end
			if _proto == nil or _proto == "" then _proto = "tcp" end
			table.insert(_options.publish, { hAddr = _hAddr, hport = _hport, cport = _cport, proto = _proto })
		elseif v.id == "subnet" then 
			_options.subnet = v.value
		elseif v.id == "nameservers" or v.id == "ns" then
			local _nameservers = {}
			for w in string.gmatch(v.value, "[^,]*") do
				table.insert(_nameservers, w)
			end
			if #_nameservers > 0 then 
				_options.nameservers = _nameservers
			end
		elseif v.id == "default-outbound-addr" or v.id == "masquerade" then
			_options.masquerade = true
		elseif v.id == "remove" then
			_options.remove = true
		elseif v.id == "localhost" then
			if type(v.value) == "string" then
				_options.localhost = v.value
			else
				_options.localhost = true
			end
		elseif v.id == "force" then
			_options.force = true
		end
	end
	::CONTINUE::
end

local function _safe_exec(...)
	local _cmd = string.join(" ", ...)
	_info("Executing: " .. _cmd)
	local _result = proc.exec(_cmd, {
		stdout = "pipe",
		stderr = "pipe"
	})
	if _result.exitcode ~= 0 then
		return false, _result
	end
	return true, _result
end

local function _exec(...)
	local _cmd = string.join(" ", ...)
	local _ok, _result = _safe_exec(_cmd)
	if not _ok then 
		_error("Failed to execute: " .. _cmd)
		if _result.stderrStream ~= nil and type(_result.stderrStream.read) == "function" then
			print(_result.stderrStream:read("a"))
		end
		os.exit(5)
	end
	return _result
end

local _netnsId =  _options.id
if type(_netnsId) ~= "string" or #_netnsId < 4 then 
	_error("Invalid netns ID!")
	os.exit(1)
end
local _netnsRunFile = "/var/run/" .. _options.id

if fs.exists(_netnsRunFile) then
	if _options.remove or _options.force then
		os.remove("/etc/netns/" .. _netnsId .. "/resolv.conf")
		local _ok, _rf = fs.safe_read_file(_netnsRunFile)
		if not _ok then 
			_error("Failed to read config file '" .. _netnsRunFile .. "'!")
			os.exit(4)
		end
		local _ok, _netnsRunConfig = pcall(_hjson.parse, _rf)
		if not _ok then 
			_error("Failed to parse config file '" .. _netnsRunFile .. "'!")
			os.exit(7)
		end

		if _safe_exec("iptables -C FORWARD -s", _netnsRunConfig.vecIp .. "/30", "-j ACCEPT") then
			_safe_exec("iptables -D FORWARD -s", _netnsRunConfig.vecIp .. "/30", "-j ACCEPT")
		end
		if _safe_exec("iptables -C FORWARD -d", _netnsRunConfig.vecIp .. "/30", "-j ACCEPT") then
			_safe_exec("iptables -D FORWARD -d", _netnsRunConfig.vecIp .. "/30", "-j ACCEPT")
		end
		if _netnsRunConfig.masquerade then
			if _safe_exec("iptables -t nat -C POSTROUTING -s", _netnsRunConfig.vecIp .. "/30", "-j MASQUERADE") then
				_safe_exec("iptables -t nat -D POSTROUTING -s", _netnsRunConfig.vecIp .. "/30", "-j MASQUERADE")
			end
		else
			if _safe_exec("iptables -t nat -C POSTROUTING -s", _netnsRunConfig.vecIp .. "/30", "-j SNAT --to-source", _netnsRunConfig.outboundAddr) then
				_safe_exec("iptables -t nat -D POSTROUTING -s", _netnsRunConfig.vecIp .. "/30", "-j SNAT --to-source", _netnsRunConfig.outboundAddr)
			end
		end
		for _, v in ipairs(_netnsRunConfig.publish) do
			if _safe_exec("iptables -t nat -C PREROUTING -p", v.proto, "-d", v.hAddr, "--dport", v.hport, "-j DNAT --to-destination", _netnsRunConfig.vecIp .. ":" .. v.cport) then
				_safe_exec("iptables -t nat -D PREROUTING -p", v.proto, "-d", v.hAddr, "--dport", v.hport, "-j DNAT --to-destination", _netnsRunConfig.vecIp .. ":" .. v.cport)
			end
		end

		if _options.force then 
			_safe_exec("ip netns delete", _netnsId)
			_safe_exec("ip link delete", _netnsRunConfig.vehId)
		else 
			_exec("ip netns delete", _netnsId)
			_exec("ip link delete", _netnsRunConfig.vehId)
		end
		fs.remove(_netnsRunFile)
		if _options.remove then os.exit(0) end
	else
		_error("Found runtime info about netns '" .. _netnsId .. "'.")
		_info("Remove existing runtime info or run with '--force' to automatically cleanup.")
		os.exit(3)
	end
elseif _options.remove then -- nothing to be removed
	os.exit(0)
end

local _invalidOutboundAddr = false
if type(_options.outboundAddr) ~= "string" or not _options.outboundAddr:match("[^%.]*%.[^%.]*%.[^%.]*%.[^/]*") then 
	_invalidOutboundAddr = true
end

-- we keep masquerade only if outbound addr is not specified
_options.masquerade = _options.masquerade and _invalidOutboundAddr

if _invalidOutboundAddr and not _options.masquerade then
	_error("Invalid netns outbound addr!")
	os.exit(2)
end

local function _exec_in_netns(...)
	return _exec("ip netns exec", _netnsId, ...)
end

local _hash = hash.sha256sum("veth-".._netnsId, true)
local _vethId = _netnsId:sub(1, 5)
local _vethhash = _hash:sub(1, 5)
local _vehId = "veh-" .. _vethId .. _vethhash
local _vecId = "vec-" .. _vethId .. _vethhash

local _range = _ip.get_next_available_cidr(_options.subnet, 30)
local _vehIp = _ip.n_to_ipv4(_range.__hostMin)
local _vecIp = _ip.n_to_ipv4(_range.__hostMin + 1)

local runtimeconfig = {
	id = _netnsId,
	vehId = _vehId,
	vecIp = _vecIp,
	publish = _options.publish,
	outboundAddr = _options.outboundAddr,
	masquerade = _options.masquerade
}
if not fs.safe_write_file(_netnsRunFile, _hjson.stringify_to_json(runtimeconfig)) then
	error("Failed to write runtime config!")
	os.exit(6)
end

_safe_exec("ip netns delete", _netnsId)
local _result = _exec("flock --no-fork -- /var/run/netns.lock ip netns add", _netnsId)
-- patch ubuntu 16.04
if _result.exitcode == 0 and _result.stderrStream ~= nil and _result.stderrStream:read("a"):match("unrecognized option") then 
	_exec("flock -- /var/run/netns.lock ip netns add", _netnsId)
end

local _resolvConf = ""
for _, v in ipairs(_options.nameservers) do 
	_resolvConf = _resolvConf .. "nameserver " .. v .. "\n"
end

_info("Creating namespaced resolv.conf")
fs.mkdirp("/etc/netns/" .. _netnsId)
fs.write_file("/etc/netns/" .. _netnsId .. "/resolv.conf", _resolvConf)

_safe_exec("ip link delete", _vehId)
_exec("ip link add", _vehId, "type veth peer name", _vecId)
_exec("ip link set", _vecId, "netns" , _netnsId)

_exec("ip addr add", _vehIp .. "/30", "dev", _vehId)
_exec_in_netns("ip addr add", _vecIp .. "/30", "dev", _vecId)
if _options.localhost then
	_exec_in_netns("ip link set dev", type(_options.localhost) == "boolean" and "lo" or _options.localhost, "up")
end

_exec("sysctl -w net.ipv4.conf.all.forwarding=1")
_exec_in_netns("sysctl -w net.ipv4.ip_unprivileged_port_start=0")

_exec("ip link set", _vehId, "up")
_exec_in_netns("ip link set", _vecId, "up")
_exec_in_netns("ip route add default via", _vehIp)

if not _safe_exec("iptables -C FORWARD -s", _vecIp .. "/30", "-j ACCEPT") then
	_exec("iptables -I FORWARD -s", _vecIp .. "/30", "-j ACCEPT")
end
if not _safe_exec("iptables -C FORWARD -d", _vecIp .. "/30", "-j ACCEPT") then
	_exec("iptables -I FORWARD -d", _vecIp .. "/30", "-j ACCEPT")
end

if _options.masquerade then
	if not _safe_exec("iptables -t nat -C POSTROUTING -s", _vecIp .. "/30", "-j MASQUERADE") then
		_exec("iptables -t nat -I POSTROUTING -s", _vecIp .. "/30", "-j MASQUERADE")
	end
else 
	if not _safe_exec("iptables -t nat -C POSTROUTING -s", _vecIp .. "/30", "-j SNAT --to-source", _options.outboundAddr) then
		_exec("iptables -t nat -I POSTROUTING -s", _vecIp .. "/30", "-j SNAT --to-source", _options.outboundAddr)
	end
end

for _, v in ipairs(_options.publish) do
	if not _safe_exec("iptables -t nat -C PREROUTING -p", v.proto, "-d", v.hAddr, "--dport", v.hport, "-j DNAT --to-destination", _vecIp .. ":" .. v.cport) then
		_exec("iptables -t nat -I PREROUTING -p", v.proto, "-d", v.hAddr, "--dport", v.hport, "-j DNAT --to-destination", _vecIp .. ":" .. v.cport)
	end
end

_success("Netns '" .. _netnsId .. "' configured.")